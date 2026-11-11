# Протокол для самопроверки

## Окружение

| Параметр           | Значение                                                                      |
|--------------------|-------------------------------------------------------------------------------|
| PostgreSQL version | `PostgreSQL 15.19 (Debian 15.19-1.pgdg13+2)`, Docker `postgres:15`, чистая БД |
| Дата проверки      | 2026-11-11                                                                    |
| Схема              | `kuznetsova_food`                                                             |
| Роль-аудитор       | `inspector` (`rolsuper = f`)                                                  |
| Бэкап              | `db/foodexpress_kuznetsova.backup` (`pg_dump -Fc` 15.19)                      |

Все проверки — под `inspector`, если не указано иное.

## Итог

| Раздел                           | Проверок | Вердикт |
|----------------------------------|----------|---------|
| A. Подготовка                    | 2        | OK      |
| B. FOOD-101: структура схемы     | 7        | OK      |
| C. FOOD-102: `insert_test_data`  | 9        | OK      |
| D. Бизнес-правила на данных      | 14       | OK      |
| E. Функции и процедуры           | 7        | OK      |
| F. `how_much_money`              | 4        | OK      |
| G. Права `inspector`             | 5        | OK      |
| H. Оптимизация `get_statistic`   | 3        | OK      |
| I. Очистка и повторная генерация | 3        | OK      |

**FAIL нет.** E.1 и E.3 выполнены корректным вызовом: шаблонный вариант в PostgreSQL невыполним (подробности в пунктах).

---

## A. Подготовка

### A.1. Восстановление бэкапа

**Запрос** (под `postgres`):

```bash
createdb -U postgres audit
psql -U postgres -d audit -c 'create schema exts' -c 'create extension "uuid-ossp" schema exts'
pg_restore -U postgres -d audit --exit-on-error -v db/foodexpress_kuznetsova.backup
psql -U postgres -d audit -v ON_ERROR_STOP=1 -f db/schema/grants.sql
```

**Ожидается:** без ошибок.
**Результат:** код выхода 0 у всех команд, ошибок и предупреждений нет — **OK**

### A.2. Переключение на inspector

**Запрос:**

```sql
SET ROLE inspector;
SET search_path TO kuznetsova_food, exts;
SELECT current_user;
```

**Ожидается:** `inspector`.
**Результат:** `inspector`. — **OK**

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

**Запрос:**

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```

**Ожидается:** `kuznetsova_food`.
**Результат:** `kuznetsova_food`. — **OK**

### B.2. Схема `exts` с `uuid-ossp`

**Запрос:**

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```

**Ожидается:** `uuid-ossp`, схема `exts`.
**Результат:** `uuid-ossp | exts`. — **OK**

### B.3. Все 12 исходных таблиц + N после нормализации

**Запрос:**

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'kuznetsova_food'
ORDER BY table_name;
```

**Ожидается:** `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` (12 + N).
**Результат:** 12 таблиц из списка + представление `how_much_money` (`information_schema.tables` показывает и представления). N = 0, обоснование — `constraints.md`, раздел «Нормализация». — **OK**

### B.4. Все PK — `uuid`

**Запрос:**

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'kuznetsova_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';
```

**Ожидается:** пусто.
**Результат:** пусто. — **OK**

### B.5. Enum-типы

**Запрос:**

```sql
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'kuznetsova_food'
GROUP BY t.typname
ORDER BY t.typname;
```

**Ожидается:** 8 типов со значениями из `constraints.md`.
**Результат:** 8 типов, значения совпадают с `constraints.md`:

| typname              | values                                            |
|----------------------|---------------------------------------------------|
| `courier_status`     | `{свободен,занят,на_доставке,уволен}`             |
| `order_pay_status`   | `{ожидает,оплачен,ошибка}`                        |
| `order_status`       | `{создан,готовится,в_доставке,доставлен,отменён}` |
| `payment_status`     | `{успех,ошибка,в_обработке}`                      |
| `payment_type`       | `{карта,наличные,безнал}`                         |
| `product_status`     | `{доступно,нет_в_наличии,архив}`                  |
| `restaurant_status`  | `{активен,неактивен}`                             |
| `review_entity_type` | `{блюдо,ресторан,заказ}`                          |

**OK**

### B.6. FK-ограничения

**Запрос:**

```sql
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'kuznetsova_food'::regnamespace
ORDER BY tbl, conname;
```

**Ожидается:** не менее 15 FK, все из `erd.md`.
**Результат:** 18 FK — все 15 связей ERD + 3 составных (`order_client_address_fk`, `payment_order_amount_fk`, `review_order_client_fk`). — **OK**

### B.7. Пароль — MD5

**Запрос:**

```sql
SELECT length(password) AS len, password
FROM client LIMIT 5;
```

**Ожидается:** `len = 32`, hex-строка.
**Результат:** во всех 5 строках `len = 32`, hex (например, `f1de8f8a52339db30deda93e03792095`). — **OK**

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

**Запрос:**

```sql
CALL erase_test_data();
```

**Ожидается:** без ошибок.
**Результат:** без ошибок. — **OK**

### C.2. Первый запуск

**Запрос:**

```sql
CALL insert_test_data(10);
```

**Ожидается:** без ошибок.
**Результат:** без ошибок. — **OK**

### C.3. Распределение строк (BR-11.7)

**Запрос:**

```sql
SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
ORDER BY tbl;
```

**Ожидается:** 10, 10, 10, 10, 50, 50, 50, 50, 50.
**Результат:** `address 50`, `client 10`, `courier 10`, `order 50`, `payment 50`, `product 50`, `product_category 10`, `restaurant 10`, `review 50`. — **OK**

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

**Запрос:**

```sql
SELECT 'restaurant addresses' AS cat, count(*) FROM restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'total addresses', count(*) FROM address;
```

**Ожидается:** 10 ресторанных адресов, 50 всего -> 40 клиентских.
**Результат:** `10` / `50`. — **OK**

### C.5. Нет пустых строк (BR-11.3)

**Запрос:**

```sql
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '';
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### C.6. Нет NULL там, где запрещено (BR-11.3)

**Запрос:**

```sql
SELECT count(*) FROM "order" WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### C.7. Минимум один активный курьер (BR-6.6)

**Запрос:**

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

**Ожидается:** `>= 1`.
**Результат:** `8`. — **OK**

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

**Запрос:**

```sql
SELECT cp.year, cp.month, cp.courier_id, cp.amount, cp.coefficient_used,
       round(coalesce((
           SELECT sum(o.commission)
           FROM "order" o
           WHERE o.courier_id = cp.courier_id
             AND o.status = 'доставлен'
             AND extract(year  from o.order_timestamp) = cp.year
             AND extract(month from o.order_timestamp) = cp.month
       ), 0) * cp.coefficient_used, 2) AS expected_amount
FROM courier_pay cp
LIMIT 20;
```

**Ожидается:** `amount = expected_amount` в каждой строке.
**Результат:** 20 из 20 строк совпадают (например, `2026 | 7 | … | 83.67 | 0.10 | 83.67`). — **OK**

### C.9. Повторный вызов не ломает

**Запрос:**

```sql
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;
```

**Ожидается:** без ошибок, данные добавляются или заменяются (по решению, задокументированному в `constraints.md`).
**Результат:** без ошибок. Данные добавляются (решение описано в `constraints.md`): `client 110`, `courier 110`, `product_category 110`, `restaurant 110`, `address 550`, `product 550`, `order 550`, `review 550`, `payment 550`. — **OK**

---

## D. Проверки бизнес-правил на сгенерированных данных

Выполнены после C.9 (11 пакетов, 550 заказов).

### D.1. Все FK валидны (нет orphans)

**Запрос:**

```sql
SELECT 'order_structure -> order' AS fk, count(*) AS orphans
FROM order_structure os
LEFT JOIN "order" o ON os.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_structure -> product', count(*)
FROM order_structure os
LEFT JOIN product p ON os.product_id = p.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'payment -> order', count(*)
FROM payment pmt
LEFT JOIN "order" o ON pmt.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'review -> order', count(*)
FROM review r
LEFT JOIN "order" o ON r.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'courier_pay -> courier', count(*)
FROM courier_pay cp
LEFT JOIN courier c ON cp.courier_id = c.courier_id
WHERE c.courier_id IS NULL
UNION ALL
SELECT 'client_address -> client', count(*)
FROM client_address ca
LEFT JOIN client c ON ca.client_id = c.client_id
WHERE c.client_id IS NULL
UNION ALL
SELECT 'client_address -> address', count(*)
FROM client_address ca
LEFT JOIN address a ON ca.address_id = a.address_id
WHERE a.address_id IS NULL;
```

**Ожидается:** все 0.
**Результат:** 0 во всех 7 строках. — **OK**

### D.2. Минимальная сумма заказа (BR-1.8)

**Запрос:**

```sql
SELECT count(*) FROM "order" WHERE total_amount < 1000;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.3. Комиссия = 10% (BR-1.4)

**Запрос:**

```sql
SELECT count(*) FROM "order" WHERE round(order_amount * 0.10, 2) != commission;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.4. `total_amount = order_amount + commission`

**Запрос:**

```sql
SELECT count(*) FROM "order"
WHERE round(order_amount + commission, 2) != total_amount;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.5. Дата доставки не раньше создания (BR-7.13)

**Запрос:**

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

**Запрос:**

```sql
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.7. Все блюда в заказе из одного ресторана (BR-7.3)

**Запрос:**

```sql
SELECT count(DISTINCT os.order_id)
FROM order_structure os
JOIN "order" o ON os.order_id = o.order_id
JOIN product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.8. Ровно одна успешная оплата на заказ (BR-8.1)

**Запрос:**

```sql
SELECT order_id, count(*) AS cnt
FROM payment
WHERE status = 'успех'
GROUP BY order_id
HAVING count(*) != 1;
```

**Ожидается:** пусто.
**Результат:** пусто. — **OK**

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

**Запрос:**

```sql
SELECT count(*) FROM payment p
JOIN "order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.10. Нет дубликатов в `client_address` (BR-2.5)

**Запрос:**

```sql
SELECT client_id, address_id, count(*)
FROM client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;
```

**Ожидается:** пусто.
**Результат:** пусто. — **OK**

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

**Запрос:**

```sql
SELECT order_id, product_id, count(*)
FROM order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;
```

**Ожидается:** пусто.
**Результат:** пусто. — **OK**

### D.12. `work_end > work_start` (BR-4.4)

**Запрос:**

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.13. `dismissal_date >= hire_date` (BR-6.3)

**Запрос:**

```sql
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```

**Ожидается:** 0.
**Результат:** `0`. — **OK**

### D.14. Рейтинг блюд соответствует отзывам (BR-9.6)

**Запрос:**

```sql
SELECT p.product_id, p.rating,
       (SELECT round(avg(r.rating), 2) FROM review r
        WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id) AS expected
FROM product p
WHERE p.rating IS NOT NULL
LIMIT 20;
```

**Ожидается:** `rating = expected`.
**Результат:** 20 из 20 строк совпадают. — **OK**

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

Шаблонный вызов с подзапросами в аргументах отклоняется самим PostgreSQL (`ERROR: cannot use subquery in CALL argument`), поэтому ID переданы значениями через `\gset`.

**Запрос:**

```sql
SELECT restaurant_id AS rest_id FROM restaurant ORDER BY restaurant_name LIMIT 1 \gset
SELECT product_category_id AS cat_id FROM product_category ORDER BY product_category_name LIMIT 1 \gset

SELECT count(*) AS before FROM product;

CALL add_product(
    p_restaurant_id => :'rest_id',
    p_product_category_id => :'cat_id',
    p_name => 'Тестовое блюдо',
    p_price => 250,
    p_rating => 4.5,
    p_status => 'доступно',
    p_description => 'Описание',
    p_photo_url => 'https://cdn.foodexpress.ru/img/test.jpg'
);

SELECT count(*) AS after FROM product;
```

**Ожидается:** `after = before + 1`.
**Результат:** `NOTICE: add_product: добавлено блюдо … («Тестовое блюдо»)`, `before = 550` -> `after = 551`. — **OK**

### E.2. `add_product` — падает на несуществующий ресторан

**Запрос:**

```sql
CALL add_product(
    p_restaurant_id => '00000000-0000-0000-0000-000000000000',
    p_product_category_id => :'cat_id',
    p_name => 'Блюдо',
    p_price => 250,
    p_description => 'Описание'
);
```

**Ожидается:** ошибка с внятным сообщением.
**Результат:** `ERROR: add_product: ресторан 00000000-0000-0000-0000-000000000000 не существует`, `HINT: BR-5.1: блюдо можно добавить только существующему ресторану.` — **OK**

### E.3. `rating_change` — пересчитывает рейтинг

Шаблонный `INSERT` (первый клиент, первый заказ, первое блюдо) схема отклоняет: `duplicate key value violates unique constraint "review_order_entity_uq"` (BR-9.5) — случайная тройка нарушает BR-9.2/BR-9.5. Поэтому выбрана корректная тройка: блюдо из заказа, клиент этого заказа, отзыва на это блюдо в заказе ещё нет.

**Запрос:**

```sql
SELECT os.product_id AS pid, o.order_id AS oid, o.client_id AS cid, p.rating AS rating_before
FROM order_structure os
JOIN "order" o USING (order_id)
JOIN product p USING (product_id)
WHERE p.rating IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM review r
                  WHERE r.order_id = o.order_id
                    AND r.entity_type = 'блюдо'
                    AND r.entity_id = os.product_id)
LIMIT 1 \gset

INSERT INTO review (review_id, client_id, review_timestamp, entity_id, entity_type, order_id, description, rating)
VALUES (exts.uuid_generate_v4(), :'cid', localtimestamp, :'pid', 'блюдо', :'oid', 'Тестовый отзыв', 5)
RETURNING review_id AS rid \gset

SELECT rating FROM product WHERE product_id = :'pid';
```

**Ожидается:** `rating` пересчитан.
**Результат:** до вставки `3.00` (3 отзыва), после — `3.50` = `round(AVG, 2)` по `{1, 3, 5, 5}`. — **OK**

### E.4. `rating_change` — удаление отзыва

**Запрос:**

```sql
DELETE FROM review WHERE review_id = :'rid';

SELECT rating FROM product WHERE product_id = :'pid';
```

**Ожидается:** если других отзывов нет — `rating IS NULL`; иначе — пересчитан.
**Результат:** `3.00` = `round(AVG, 2)` по трём оставшимся отзывам. — **OK**

### E.5. `get_statistic()`

**Запрос:**

```sql
SELECT * FROM get_statistic();
```

**Ожидается:**
- колонки `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`;
- по одной строке на ресторан;
- `best_user` = `client.login` (не `NULL` при наличии заказов).

**Результат:** колонки совпадают; 110 строк на 110 ресторанов; `best_user` — существующий `client.login`, `NULL` нет. Пример:

| restaurant_name | best_product_name | total_amount | avg_amount | best_user |
|---|---|---|---|---|
| Бистро «Берёзка» | Фирменный борщ | 11553.30 | 2888.33 | dmitry_9722793b6 |
| Бистро «Венеция» | Фирменный борщ | 20653.60 | 5163.40 | anna_28f6ac8 |
| Бистро «Восток» | Классический борщ | 19644.35 | 3274.06 | alex_5eadc7f8d5 |

**OK**

### E.6. `courier_salary()`

**Запрос:**

```sql
-- До
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;

CALL courier_salary();

-- После
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;
SELECT year, month, courier_id, amount, coefficient_used
FROM courier_pay
ORDER BY year DESC, month DESC, courier_id
LIMIT 20;
```

**Ожидается:**
- `courier.coefficient` пересчитан для работающих (BR-10.2);
- у уволенных — не изменился;
- `courier_pay` содержит запись за текущий месяц.

**Результат:** `NOTICE: courier_salary: 2026-11: выплат записано 110, коэффициентов обновлено 92` (92 работающих, 18 уволенных пропущены). Запись за `2026-11` есть у всех 110 курьеров. Коэффициенты работающих соответствуют BR-10.2 (доставок за месяц ≤ 150 -> `0.10`), у уволенных не изменились. — **OK**

### E.7. `courier_salary()` — повторный вызов

**Запрос:**

```sql
CALL courier_salary();
SELECT count(*) FROM courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);
```

**Ожидается:** количество не изменилось.
**Результат:** `110` до и `110` после; суммы и коэффициенты не изменились. — **OK**

---

## F. Представление `how_much_money`

### F.1. Колонки

**Запрос:**

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'kuznetsova_food'
  AND table_name = 'how_much_money'
ORDER BY ordinal_position;
```

**Ожидается:** `year_month` (text), `sum_no_commission`, `sum_with_commission`, `commission`, `prev_commission`, `commission_diff`, `courier_pay`, `net_profit` (numeric).
**Результат:** `year_month text`, остальные 7 колонок — `numeric`, порядок совпадает. — **OK**

### F.2. Месяцы покрыты

**Запрос:**

```sql
SELECT * FROM how_much_money ORDER BY year_month;
```

**Ожидается:** месяцы от первого доставленного заказа до последнего, без пропусков.
**Результат:** 6 месяцев подряд, пропусков нет:

| year_month | sum_no_commission | sum_with_commission | commission | prev_commission | commission_diff | courier_pay | net_profit |
|------------|-------------------|---------------------|------------|-----------------|-----------------|-------------|------------|
| 2026-06    | 314479.00         | 345926.90           | 31447.90   | NULL            | NULL            | 3144.81     | 28303.09   |
| 2026-07    | 398386.00         | 438224.60           | 39838.60   | 31447.90        | 8390.70         | 3983.91     | 35854.69   |
| 2026-08    | 359913.00         | 395904.30           | 35991.30   | 39838.60        | -3847.30        | 3599.17     | 32392.13   |
| 2026-09    | 289783.00         | 318761.30           | 28978.30   | 35991.30        | -7013.00        | 2897.87     | 26080.43   |
| 2026-10    | 393207.00         | 432527.70           | 39320.70   | 28978.30        | 10342.40        | 3932.12     | 35388.58   |
| 2026-11    | 162794.00         | 179073.40           | 16279.40   | 39320.70        | -23041.30       | 1627.95     | 14651.45   |

**OK**

### F.3. Месяцы без заказов присутствуют (BR-11.9)

**Запрос:**

```sql
SELECT year_month FROM how_much_money
WHERE sum_no_commission = 0 OR sum_no_commission IS NULL;
```

**Ожидается:** если в какие-то месяцы заказов не было — они есть в результате.
**Результат:** пусто — в сгенерированных данных доставки есть в каждом месяце. — **OK**

### F.4. Корректность сумм

**Запрос:**

```sql
SELECT year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       prev_commission,
       commission_diff,
       courier_pay,
       net_profit
FROM how_much_money
ORDER BY year_month
LIMIT 10;
```

**Ожидается:**
- `commission = sum_with_commission - sum_no_commission`;
- `commission_diff = commission - prev_commission` (`NULL` для первого месяца);
- `net_profit = commission - courier_pay`.

**Результат:** все три формулы выполняются в 6 из 6 строк; `prev_commission` и `commission_diff` равны `NULL` только у первого месяца. — **OK**

---

## G. Права `inspector`

### G.1. Права на схему

**Запрос:**

```sql
SELECT
    nspname AS schema_name,
    has_schema_privilege('inspector', nspname, 'USAGE')  AS usage,
    has_schema_privilege('inspector', nspname, 'CREATE') AS create
FROM pg_namespace
WHERE nspname = 'kuznetsova_food';
```

**Ожидается:** `kuznetsova_food`, `true`, `true`.
**Результат:** `kuznetsova_food | t | t`. — **OK**

### G.2. Права на таблицы

**Запрос:**

```sql
SELECT table_name, string_agg(privilege_type, ', ') AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'kuznetsova_food'
GROUP BY table_name;
```

**Ожидается:** у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).
**Результат:** у всех 12 таблиц и `how_much_money` — `DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE` (`ALL`). — **OK**

### G.3. `information_schema` читается под `inspector`

**Запрос:**

```sql
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'kuznetsova_food';
RESET ROLE;
```

**Ожидается:** 12 + N.
**Результат:** `13` — 12 таблиц + представление `how_much_money` (см. B.3). — **OK**

### G.4. `pg_catalog` читается под `inspector`

**Запрос:**

```sql
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname = 'kuznetsova_food';
RESET ROLE;
```

**Ожидается:** 12 + N.
**Результат:** `12` (`pg_tables` показывает только таблицы, без представлений). — **OK**

### G.5. Все процедуры/функции работают под `inspector`

**Запрос:**

```sql
SET ROLE inspector;
SET search_path TO kuznetsova_food, exts;

CALL erase_test_data();
CALL insert_test_data(10);
CALL courier_salary();
SELECT * FROM get_statistic();
SELECT * FROM how_much_money LIMIT 5;

RESET ROLE;
```

**Ожидается:** без `permission denied`.
**Результат:** без ошибок. `courier_salary` — `выплат записано 10, коэффициентов обновлено 7`, `get_statistic` — 10 строк, `how_much_money` — 5 строк. — **OK**

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. `EXPLAIN ANALYZE` — паттерн «избыточные подзапросы»

**Запрос:**

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       (SELECT count(*) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS cnt,
       (SELECT coalesce(sum(commission), 0) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS commission_sum
FROM courier c;
```

**Ожидается:** два SubPlan, каждый — скан `"order"`; время растёт с числом курьеров.
**Результат:** 0.354 мс. План: `Seq Scan on courier` + `SubPlan 1` и `SubPlan 2`, в каждом `Aggregate -> Bitmap Heap Scan on "order"`, `loops=10`. — **OK**

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

**Запрос:**

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       count(o.order_id) AS cnt,
       coalesce(sum(o.commission), 0) AS commission_sum
FROM courier c
LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
GROUP BY c.courier_id;
```

**Ожидается:** один `Hash Right/Left Join`, один скан `"order"`, время меньше, чем в H.1.
**Результат:** 0.168 мс. План: `HashAggregate -> Hash Right Join`, один `Seq Scan on "order"`, один `Seq Scan on courier`. — **OK**

### H.3. Применить к `get_statistic`

`EXPLAIN` вызова функции показывает только `Function Scan` (SQL-функция с `SET search_path` не инлайнится), поэтому план тела функции снят отдельно.

**Запрос:**

```sql
EXPLAIN ANALYZE SELECT * FROM get_statistic();

SELECT prosrc AS body FROM pg_proc WHERE oid = 'get_statistic()'::regprocedure \gset
EXPLAIN (ANALYZE, COSTS off) :body
```

**Ожидается:** без `LATERAL`, без множественных подзапросов к одной таблице, без оконных функций там, где хватает агрегата.
**Результат:** `Function Scan on get_statistic … rows=10`, 3.49 мс. План тела — 0.651 мс: каждая таблица читается один раз (`"order"` — в CTE, используется через `CTE Scan`), `SubPlan`, `LATERAL` и `WindowAgg` нет; только `HashAggregate`/`GroupAggregate` и `Hash Join`. — **OK**

---

## I. Очистка и повторная генерация

### I.1. `erase_test_data` очищает всё

**Запрос:**

```sql
CALL erase_test_data();

SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'order_structure', count(*) FROM order_structure
UNION ALL SELECT 'client_address', count(*) FROM client_address
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay;
```

**Ожидается:** все 0.
**Результат:** все 12 — `0`. — **OK**

### I.2. Повторный `erase_test_data` не падает

**Запрос:**

```sql
CALL erase_test_data();
```

**Ожидается:** без ошибок.
**Результат:** без ошибок. — **OK**

### I.3. После очистки `insert_test_data` снова работает

**Запрос:**

```sql
CALL insert_test_data(10);
SELECT count(*) FROM "order";
```

**Ожидается:** 50.
**Результат:** `50`. — **OK**
