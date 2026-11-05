-- Практика 8. Индексы и EXPLAIN (числа из моего прогона, подставь свои)

DROP INDEX IF EXISTS idx_orders_customer_date, idx_orders_cancelled_date,
                     idx_items_product, idx_orders_status, idx_orders_date;

-- ЧАСТЬ A. Исходная база

-- Контроль: 1000 / 300 / 60000 / 240000
SELECT (SELECT COUNT(*) FROM customers) AS customers,
       (SELECT COUNT(*) FROM products) AS products,
       (SELECT COUNT(*) FROM orders) AS orders,
       (SELECT COUNT(*) FROM order_items) AS order_items;

ANALYZE customers;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;

-- Сейчас только индексы первичных ключей
SELECT tablename, indexname FROM pg_indexes
WHERE tablename IN ('orders', 'order_items');

-- A1. Seq Scan, estimated rows 60
EXPLAIN SELECT * FROM orders WHERE customer_id = 700;

-- A2. Seq Scan, estimated rows около 26000
EXPLAIN SELECT * FROM orders WHERE status = 'paid';

-- A3. Seq Scan, estimated rows около 2500
EXPLAIN SELECT * FROM orders
WHERE order_date >= TIMESTAMP '2026-06-01' AND order_date < TIMESTAMP '2026-07-01';

-- A4. Hash Join, два Seq Scan, сверху GroupAggregate
EXPLAIN
SELECT o.order_id, SUM(oi.quantity * oi.unit_price)
FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.customer_id = 700
GROUP BY o.order_id;

-- ЧАСТЬ B. Эксперименты

-- Эксперимент 1. Гипотеза: индекс (customer_id, order_date DESC) уберёт Sort.
-- До: Seq Scan + Sort, estimated 60, actual 60, loops 1, Buffers 408, 3.3 ms
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, status FROM orders
WHERE customer_id = 700 ORDER BY order_date DESC LIMIT 20;

CREATE INDEX idx_orders_customer_date ON orders(customer_id, order_date DESC);
ANALYZE orders;

-- После: Index Scan, Sort нет, estimated 60, actual 20, loops 1, Buffers около 23, 0.07 ms
-- Вывод: индекс сразу отдаёт строки по порядку, читаем 20 строк вместо всей таблицы
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, status FROM orders
WHERE customer_id = 700 ORDER BY order_date DESC LIMIT 20;

-- Контроль: 60 заказов у клиента
SELECT COUNT(*) FROM orders WHERE customer_id = 700;

-- Эксперимент 2. Гипотеза: cancelled редкий (1%), частичный индекс будет маленьким и быстрым.
-- До: Seq Scan, estimated 300, actual 257, loops 1, Buffers 408, 3.9 ms
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date FROM orders
WHERE status = 'cancelled' AND order_date >= DATE '2026-01-01';

CREATE INDEX idx_orders_cancelled_date ON orders(order_date) WHERE status = 'cancelled';
ANALYZE orders;

-- После: Bitmap Heap Scan, estimated 297, actual 257, loops 1, Buffers около 209, 0.4 ms
-- Вывод: условие запроса совпало с WHERE индекса, он подошёл
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date FROM orders
WHERE status = 'cancelled' AND order_date >= DATE '2026-01-01';

-- Размер: частичный 32 kB, полный 1872 kB
SELECT pg_size_pretty(pg_relation_size('idx_orders_cancelled_date')) AS partial_index,
       pg_size_pretty(pg_relation_size('idx_orders_customer_date')) AS full_index;

-- Контроль: 257 строк
SELECT COUNT(*) FROM orders
WHERE status = 'cancelled' AND order_date >= DATE '2026-01-01';

-- Эксперимент 3. Гипотеза: FOREIGN KEY не создаёт индекс, индекс по product_id ускорит поиск.
-- До: Parallel Seq Scan, estimated 262, actual 100 на воркера, loops 2, Buffers 1529, 13 ms
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(quantity * unit_price) AS revenue, COUNT(*) AS cnt
FROM order_items WHERE product_id = 42;

-- Контроль до: cnt = 200
SELECT SUM(quantity * unit_price) AS revenue, COUNT(*) AS cnt
FROM order_items WHERE product_id = 42;

CREATE INDEX idx_items_product ON order_items(product_id);
ANALYZE order_items;

-- После: Bitmap Heap Scan, estimated 447, actual 200, loops 1, Buffers около 202, 0.3 ms
-- Вывод: читаем около 200 блоков вместо около 1500
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(quantity * unit_price) AS revenue, COUNT(*) AS cnt
FROM order_items WHERE product_id = 42;

-- Контроль после: те же revenue и cnt = 200
SELECT SUM(quantity * unit_price) AS revenue, COUNT(*) AS cnt
FROM order_items WHERE product_id = 42;

-- ЧАСТЬ C. Индекс, который не победил
-- Гипотеза: paid + completed это 84% таблицы, индекс по status не поможет.
CREATE INDEX idx_orders_status ON orders(status);
ANALYZE orders;

-- Остался Seq Scan, estimated 50486, actual 50400, Buffers 408, 10 ms
-- Вывод: читаем почти всю таблицу, последовательное чтение дешевле индекса
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM orders WHERE status IN ('paid', 'completed');

-- Размер: индекс 424 kB, таблица 3264 kB
SELECT pg_size_pretty(pg_relation_size('idx_orders_status')) AS index_size,
       pg_size_pretty(pg_relation_size('orders')) AS table_size;

DROP INDEX idx_orders_status;

-- ЧАСТЬ D. Оптимизация SQL

-- D1. Функция над колонкой против диапазона. Без индекса оба Seq Scan, 85 строк
EXPLAIN (ANALYZE) SELECT COUNT(*) FROM orders WHERE DATE(order_date) = DATE '2026-06-15';
EXPLAIN (ANALYZE) SELECT COUNT(*) FROM orders
WHERE order_date >= TIMESTAMP '2026-06-15' AND order_date < TIMESTAMP '2026-06-16';

CREATE INDEX idx_orders_date ON orders(order_date);
ANALYZE orders;

-- С индексом: DATE(...) остаётся Seq Scan (2.7 ms), диапазон идёт по индексу (0.05 ms)
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*) FROM orders WHERE DATE(order_date) = DATE '2026-06-15';
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*) FROM orders
WHERE order_date >= TIMESTAMP '2026-06-15' AND order_date < TIMESTAMP '2026-06-16';

-- Контроль: 85 и 85
SELECT (SELECT COUNT(*) FROM orders WHERE DATE(order_date) = DATE '2026-06-15') AS by_function,
       (SELECT COUNT(*) FROM orders
        WHERE order_date >= TIMESTAMP '2026-06-15'
          AND order_date < TIMESTAMP '2026-06-16') AS by_range;

-- D2. План тот же, но width 23 против 11 (меньше данных)
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 700;
EXPLAIN (ANALYZE, BUFFERS) SELECT order_id, status FROM orders WHERE customer_id = 700;

-- D3. Последние 20 заказов: Index Scan Backward, около 22 блоков, 0.05 ms
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date FROM orders
ORDER BY order_date DESC, order_id DESC LIMIT 20;

-- ИТОГ. Оставил бы индексы:
-- idx_orders_customer_date: история клиента с LIMIT
-- idx_items_product: продажи по товару (внешний ключ сам индекс не создаёт)
-- idx_orders_cancelled_date: маленький, если отчёты по отменам частые
-- idx_orders_date: диапазоны по дате и последние заказы
-- Не оставил idx_orders_status: низкая селективность, Seq Scan быстрее
