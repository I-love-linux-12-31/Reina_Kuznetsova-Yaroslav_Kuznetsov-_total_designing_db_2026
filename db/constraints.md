# Обоснование ограничений

Схема: `kuznetsova_food`. 

SQL-скрипты (запускать по порядку):

| Файл | Что делает |
|---|---|
| `db/schema/01_schema.sql` | создаёт схему `kuznetsova_food`; схема `exts` с `uuid-ossp` только используется, не пересоздаётся (BR-13.3) |
| `db/schema/02_types.sql` | 8 enum-типов |
| `db/schema/03_tables.sql` | 12 таблиц, PK / FK / UNIQUE / CHECK / NOT NULL / DEFAULT / GENERATED, индексы по FK |
| `db/schema/04_integrity_triggers.sql` | триггеры для правил, которые нельзя выразить декларативно без нарушения 3НФ |
| `db/schema/05_insert_test_data.sql` | FOOD-102: процедура `insert_test_data(value int)` |
| `db/schema/06_erase_test_data.sql` | FOOD-103: процедура `erase_test_data()` |
| `db/schema/07_add_product.sql` | FOOD-104: процедура `add_product(...)` |
| `db/schema/08_rating_change.sql` | FOOD-105: триггерная функция `rating_change()` и триггер `rating_change_trg` на `review` |
| `db/schema/09_get_statistic.sql` | FOOD-106: функция `get_statistic()` |
| `db/schema/10_courier_salary.sql` | FOOD-107: процедура `courier_salary()` |
| `db/schema/11_how_much_money.sql` | FOOD-108: представление `how_much_money` |
| `db/schema/grants.sql` | FOOD-109: пользователь `inspector` и его права; запускается последним, под суперпользователем |
| `db/foodexpress_kuznetsova.backup` | FOOD-110: архив `pg_dump -Fc` схемы `kuznetsova_food` (вместо скриптов 01–11) |

Требуется PostgreSQL 15+ (используется `UNIQUE NULLS NOT DISTINCT`). Бэкап восстанавливается `pg_restore` 15 и новее (см. FOOD-110).

## Общие решения

| Решение | Обоснование |
|---|---|
| Все ID — `uuid DEFAULT exts.uuid_generate_v4()` | BR-11.1. Значение по умолчанию позволяет вставлять строки без явного ID (в т. ч. в `add_product`, FOOD-104). |
| Даты/время — `date`, `time`, `timestamp` без часового пояса | BR-11.2: всё в часовом поясе сервера. |
| Деньги — `numeric(12,2)`, цена блюда — `numeric(10,2)` | BR-11.6. Копейки — 2 знака; 10 знаков до запятой с запасом покрывают любую сумму заказа/зарплаты. |
| Рейтинг ресторана/блюда — `numeric(3,2)` | BR-4.2, BR-5.4: диапазон 0.00–5.00; среднее хранится с точностью до сотых. |
| Рейтинг отзыва — `smallint` | BR-9.4: оценка 1–5, целое значение («звёзды»). |
| Коэффициент курьера — `numeric(3,2)` | BR-6.4: 0.10–0.50. |
| Количество в позиции — `numeric(8,3)` | BR-7.15: может быть дробным (0.5 кг), граммовая точность. |
| Телефон — `varchar(16)`, формат E.164 | BR задают только наличие телефона (BR-2.1, BR-6.1) и уникальность у клиента (BR-2.2), формат не задан, поэтому это решение по BR-11.6. Выбран международный стандарт E.164: `+`, код страны, номер, всего не больше 15 цифр. Подходят номера любых стран; `varchar(16)` = `+` и 15 цифр. Почему формат вообще проверяется — см. CHECK `client.phone_number`. |
| Пароль — `char(32)` | BR-2.3: MD5 в hex — всегда 32 символа. |
| FK без `ON DELETE CASCADE` (NO ACTION) | BR-3.5: история заказов сохраняется — нельзя удалить адрес, клиента, ресторан, курьера, блюдо, на которые ссылаются заказы. Исключения — ниже. |
| `client_address.client_id … ON DELETE CASCADE` | При удалении клиента без заказов удаляются только его связи с адресами, сами адреса остаются (BR-3.5). Если у клиента есть заказы — удаление всё равно запрещено FK из `order`. |
| `order_structure.order_id … ON DELETE CASCADE` | Позиция — часть заказа (BR-7.14) и без него не существует. |
| `"order"` — имя не меняли, используем кавычки | BR-13.1 разрешает оба варианта; имя совпадает с ERD и запросами в шаблоне тестов. |
| `payment.transaction_ref` вместо `transaction_id` | Это внешний строковый идентификатор провайдера (BR-8.3), а не uuid. Суффикс `_id` в схеме зарезервирован под uuid-ключи (проверка B.4 из `tests.md` ищет все `%_id` не типа `uuid`). |
| `courier.fio` | ERD: `FIO`; без кавычек PostgreSQL всё равно приводит имя к нижнему регистру, поэтому сразу `fio`. |

---

## Enum-типы

Значения строго как в бизнес-правилах, ничего не добавлено и не изменено.

| Тип | Значения | BR |
|---|---|---|
| `restaurant_status` | `'активен'`, `'неактивен'` | BR-4.3 |
| `product_status` | `'доступно'`, `'нет_в_наличии'`, `'архив'` | BR-5.5 |
| `courier_status` | `'свободен'`, `'занят'`, `'на_доставке'`, `'уволен'` | BR-6.2 |
| `order_status` | `'создан'`, `'готовится'`, `'в_доставке'`, `'доставлен'`, `'отменён'` | BR-7.7 |
| `order_pay_status` | `'ожидает'`, `'оплачен'`, `'ошибка'` | BR-7.9 |
| `payment_status` | `'успех'`, `'ошибка'`, `'в_обработке'` | BR-8.2 |
| `payment_type` | `'карта'`, `'наличные'`, `'безнал'` | BR-8.2, BR-8.6 |
| `review_entity_type` | `'блюдо'`, `'ресторан'`, `'заказ'` | BR-9.1 |

---

## Ловушки

### Ловушка 1: `payment` — неполная сущность

**Какие атрибуты добавил в `payment` и почему** (BR-8.2):

```
payment_type          payment_type   NOT NULL  — тип оплаты попытки (BR-8.2, BR-8.6)
amount                numeric(12,2)  NOT NULL  — сумма попытки (BR-8.2); равна total_amount
                                                 заказа — составной FK (BR-8.4)
transaction_ref       varchar(64)    NOT NULL UNIQUE — внешний ID транзакции от провайдера
                                                 (BR-8.2, BR-8.3); данных карт нет (BR-1.7, BR-8.5)
transaction_timestamp timestamp      NOT NULL DEFAULT localtimestamp — дата/время транзакции (BR-8.2)
status                payment_status NOT NULL DEFAULT 'в_обработке' — статус попытки (BR-8.2);
                                                 новая попытка начинается «в обработке»
```

Дополнительно:

- `UNIQUE (order_id) WHERE status = 'успех'` (частичный уникальный индекс) — BR-8.1: успешная попытка у заказа не более одной.
- `order.pay_status` вычисляется по попыткам триггером (BR-8.7) — см. раздел «Триггеры».

**Где хранится тип оплаты — `payment` или `order`** (BR-8.6):

```
В payment. BR-8.6 прямо говорит, что тип оплаты — атрибут попытки: у одного заказа
могут быть попытки картой, затем наличными. В order тип оплаты не хранится — иначе
он либо терял бы информацию о попытках, либо дублировал бы payment (нарушение 3НФ).
```

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

**Как обеспечено, что адрес доставки принадлежит клиенту:**

```
Составной FK на таблицу связей:

    CONSTRAINT order_client_address_fk
        FOREIGN KEY (client_id, address_id)
        REFERENCES client_address (client_id, address_id)

PK client_address (client_id, address_id) служит целевым ключом. Заказ с адресом,
не привязанным к этому клиенту, вставить невозможно; отвязать адрес от клиента,
пока по нему есть заказы, тоже нельзя (NO ACTION) — история сохраняется (BR-3.5).

Простые FK order.client_id → client и order.address_id → address тоже оставлены:
они есть в ERD (FOOD-101 требует реализовать все FK из erd.md) и явно документируют
связи. Нормализацию это не нарушает: client_id и address_id — собственные атрибуты
заказа, а составной FK лишь ограничивает их сочетание.
```

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

**Как обеспечено, что все блюда из `order.restaurant_id`:**

```
Триггер, а не составной FK.

Альтернатива — добавить order_structure.restaurant_id и два составных FK
(order_id, restaurant_id) → order и (product_id, restaurant_id) → product — отвергнута:
restaurant_id в order_structure функционально зависит от части ключа (order_id),
то есть это нарушение 2НФ, а значит и 3НФ, которой требует FOOD-101.

Реализация (04_integrity_triggers.sql):
1. order_structure_integrity_trg — BEFORE INSERT/UPDATE на order_structure:
   product.restaurant_id должен совпасть с order.restaurant_id, иначе ошибка
   check_violation с подсказкой BR-7.3.
2. order_restaurant_guard_trg — BEFORE UPDATE OF restaurant_id на "order":
   нельзя сменить ресторан у заказа, в котором уже есть позиции.
3. product_restaurant_guard_trg — BEFORE UPDATE OF restaurant_id на product:
   нельзя перенести в другой ресторан блюдо, которое уже есть в заказах.
Пункты 2–3 закрывают обходные пути: без них правило можно было бы нарушить
изменением родительской строки, а не позиции.
```

### Ловушка 4: `review` — полиморфизм (BR-9.1)

**Как реализована валидность `review.entity_id`:**

```
Гибрид: полиморфная пара (entity_type, entity_id) из ERD + декларативные
ограничения там, где это возможно, + триггер там, где FK невозможен.

Почему не обычный FK на entity_id: entity_id указывает в разные таблицы
(product / restaurant / order) в зависимости от entity_type — один FK не может
ссылаться на три таблицы. Пару сохранили, потому что на неё опирается контракт
FOOD-105 (rating_change пересчитывает по entity_type / entity_id).

Нормализацию в три nullable-столбца (product_id / restaurant_id / order_id + CHECK
«ровно один не NULL») не выбрали: она ломает контракт FOOD-105 и всё равно не даёт
главного — проверки, что клиент заказал именно это блюдо/ресторан (BR-9.2).

Что гарантирует схема:
- FK review.order_id → order и review.client_id → client — из ERD.
- FK (order_id, client_id) → order (order_id, client_id) — BR-9.2: отзыв оставляет
  тот же клиент, что оформил заказ.
- CHECK (entity_type <> 'заказ' OR entity_id = order_id) — отзыв на заказ ссылается
  на свой же заказ.
- Триггер review_entity_check_trg (BEFORE INSERT/UPDATE):
    'блюдо'    — блюдо entity_id есть в позициях этого заказа (order_structure);
    'ресторан' — entity_id = restaurant_id этого заказа.
  Значит, и существование блюда/ресторана гарантировано (через FK order_structure
  → product и order → restaurant).
- Триггер order_structure_integrity_trg (BEFORE DELETE/UPDATE) не даёт удалить
  позицию заказа, на блюдо из которой есть отзыв; order_restaurant_guard_trg — сменить
  ресторан заказа, если на ресторан есть отзыв. Так отзыв не «осиротеет».
- UNIQUE (order_id, entity_type, entity_id) — BR-9.5.
```

---

## CHECK-ограничения

Отдельно о проверках на пустую строку: `CHECK (btrim(col) <> '')` стоит на всех обязательных текстовых полях — BR-11.3 и BR-11.4 требуют, чтобы обязательное значение не было пустым и чтобы это обеспечивала схема. `NOT NULL` не отсекает `''` и строку из пробелов.

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| `address` | `street` | `btrim(street) <> ''` | BR-3.1, BR-11.3 | Улица обязательна, пустая строка — это отсутствие значения. |
| `address` | `house_number` | `btrim(house_number) <> ''` | BR-3.1, BR-11.3 | Номер дома обязателен. |
| `address` | `apartment_office` | `btrim(apartment_office) <> ''` | BR-3.2, BR-11.3 | «Квартиры нет» выражается только `NULL`, не `''`, иначе два представления одного факта и обход UNIQUE адреса. |
| `client` | `login` | `btrim(login) <> ''` | BR-2.1, BR-11.4 | Логин обязателен для регистрации. |
| `client` | `password` | `password ~ '^[0-9a-f]{32}$'` | BR-2.3 | Пароль хранится только как MD5-хэш: 32 hex-символа. Открытый пароль сохранить нельзя. |
| `client` | `phone_number` | `phone_number ~ '^\+[1-9][0-9]{6,14}$'` | BR-2.2, BR-11.6 | Единая запись номера в формате E.164 (`+`, код страны без ведущего нуля, всего 7–15 цифр, без пробелов и скобок). BR-2.2 требует уникальности телефона, а без единой записи её легко обойти: `+7 999 123-45-67`, `89991234567` и `+79991234567` — один телефон, но три разные строки. Код страны любой (`+7`, `+375`, `+49` …). |
| `restaurant` | `restaurant_name` | `btrim(restaurant_name) <> ''` | BR-4.1, BR-11.3 | Название обязательно. |
| `restaurant` | `description` | `btrim(description) <> ''` | BR-4.1, BR-11.3 | Описание обязательно. |
| `restaurant` | `company_details` | `btrim(company_details) <> ''` | BR-4.1, BR-4.5, BR-11.3 | Реквизиты обязательны. |
| `restaurant` | `work_start`, `work_end` | `work_end > work_start` | BR-4.4 | Время закрытия позже времени открытия. |
| `restaurant` | `rating` | `rating BETWEEN 0 AND 5` | BR-4.2 | Диапазон рейтинга ресторана. `NULL` проходит CHECK — так и задумано (BR-9.7). |
| `courier` | `fio` | `btrim(fio) <> ''` | BR-6.1, BR-11.3 | ФИО курьера обязательно. |
| `courier` | `phone_number` | `phone_number ~ '^\+[1-9][0-9]{6,14}$'` | BR-6.1, BR-11.6 | Тот же формат E.164, что у клиента: телефоны в схеме записываются одинаково. Уникальность телефона курьера BR не требуют, поэтому UNIQUE здесь нет. |
| `courier` | `status`, `dismissal_date` | `status <> 'уволен' OR dismissal_date IS NOT NULL` | BR-6.3 | Уволенный курьер обязан иметь дату увольнения. Обратное не требуется: «работающий — не обязан». |
| `courier` | `dismissal_date` | `dismissal_date >= hire_date` | BR-6.1, BR-6.3 | Уволить можно только после найма (даты найма и увольнения — атрибуты одного трудового периода). |
| `courier` | `coefficient` | `coefficient BETWEEN 0.1 AND 0.5` | BR-6.4 | Коэффициент от 0.1 до 0.5 включительно. |
| `courier_pay` | `year` | `year BETWEEN 2000 AND 2100` | BR-10.1, BR-11.6 | Отсекает опечатки вроде `26` или `20266`; сервис работает в современности. |
| `courier_pay` | `month` | `month BETWEEN 1 AND 12` | BR-10.1, BR-10.3 | Выплата ежемесячная, месяц — номер 1–12. Без проверки ключ «за месяц» (BR-10.3) не имеет смысла. |
| `courier_pay` | `amount` | `amount >= 0` | BR-10.4 | Сумма зарплаты неотрицательна. |
| `courier_pay` | `coefficient_used` | `coefficient_used BETWEEN 0.1 AND 0.5` | BR-6.4, BR-10.2 | Применённый коэффициент — это коэффициент курьера, тот же диапазон. |
| `product_category` | `product_category_name` | `btrim(product_category_name) <> ''` | BR-5.7, BR-11.3 | Название категории обязательно. |
| `product` | `product_name` | `btrim(product_name) <> ''` | BR-5.2, BR-11.3 | Название блюда обязательно. |
| `product` | `description` | `btrim(description) <> ''` | BR-5.2, BR-11.3 | Описание блюда обязательно. |
| `product` | `price` | `price >= 0` | BR-5.3 | Цена неотрицательна. |
| `product` | `rating` | `rating BETWEEN 0 AND 5` | BR-5.4 | Диапазон рейтинга блюда. `NULL` допустим (BR-9.7). |
| `product` | `photo_url` | `photo_url ~* '^https?://\S+$'` | BR-5.6 | Фотография — ссылка (URL). `NULL` допустим. |
| `order` | `description` | `btrim(description) <> ''` | BR-11.3 | Атрибут из ERD; BR не разрешает ему быть пустым, значит обязателен. |
| `order` | `order_amount` | `order_amount >= 0` | BR-5.3, BR-7.10 | Сумма без комиссии — стоимость блюд, а цены неотрицательны. |
| `order` | `total_amount` | `total_amount >= 1000` | BR-1.8, BR-7.11 | Минимальная сумма заказа — 1000 ₽. |
| `order` | `status`, `delivery_timestamp` | `status <> 'доставлен' OR delivery_timestamp IS NOT NULL` | BR-7.12 | У доставленного заказа время окончания доставки заполнено. До доставки — «может быть пустым», поэтому обратное условие не ставим. |
| `order` | `delivery_timestamp` | `delivery_timestamp >= order_timestamp` | BR-7.13 | Доставка не раньше создания заказа. |
| `order_structure` | `quantity` | `quantity > 0` | BR-7.15 | Количество положительное (может быть дробным). |
| `payment` | `transaction_ref` | `btrim(transaction_ref) <> ''` | BR-8.2, BR-8.3 | Идентификатор транзакции обязателен; пустая строка обошла бы UNIQUE один раз. |
| `review` | `description` | `btrim(description) <> ''` | BR-9.3, BR-11.3 | Текст отзыва обязателен. |
| `review` | `photo_url` | `btrim(photo_url) <> ''` | BR-9.3, BR-11.3 | Фото необязательно, но его отсутствие — только `NULL`. |
| `review` | `rating` | `rating BETWEEN 1 AND 5` | BR-9.4 | Рейтинг отзыва от 1 до 5. |
| `review` | `entity_type`, `entity_id`, `order_id` | `entity_type <> 'заказ' OR entity_id = order_id` | BR-9.1, BR-9.2 | Отзыв на заказ может ссылаться только на свой заказ. |

---

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `address` | `(street, house_number, apartment_office)` `NULLS NOT DISTINCT` | BR-3.3, BR-2.5 | Один физический адрес — одна строка. Иначе два ресторана делили бы один адрес через разные строки-дубли (обход BR-3.3), а клиент привязывал бы один адрес дважды (обход BR-2.5). `NULLS NOT DISTINCT` — чтобы два частных дома `(Ленина, 5, NULL)` тоже считались дубликатом. |
| `client` | `(login)` | BR-2.2 | Логин уникален. |
| `client` | `(phone_number)` | BR-2.2 | Телефон уникален. |
| `client_address` | PK `(client_id, address_id)` | BR-2.5 | Один и тот же адрес нельзя привязать к одному клиенту дважды. |
| `restaurant` | `(address_id)` | BR-3.3, BR-3.4 | У ресторана ровно один адрес, и два ресторана не делят один адрес. |
| `courier_pay` | PK `(courier_id, year, month)` | BR-10.3 | За один месяц у курьера ровно одна запись. |
| `product_category` | `(product_category_name)` | BR-5.7 | Категория — справочник; две категории с одинаковым названием неотличимы для пользователя. |
| `order` | `(order_id, client_id)` | BR-9.2 | Целевой ключ для составного FK из `review` (клиент отзыва = клиент заказа). Суперключ, новых ограничений на данные не добавляет. |
| `order` | `(order_id, total_amount)` | BR-8.4 | Целевой ключ для составного FK из `payment` (сумма попытки = сумма заказа). Суперключ. |
| `order_structure` | PK `(order_id, product_id)` | BR-7.16 | Блюдо не встречается в заказе дважды — увеличивается количество. |
| `payment` | `(transaction_ref)` | BR-8.3 | Идентификатор финансовой транзакции уникален. |
| `payment` | `(order_id) WHERE status = 'успех'` — частичный уникальный индекс | BR-8.1 | Успешная попытка у заказа не более одной. |
| `review` | `(order_id, entity_type, entity_id)` | BR-9.5 | В рамках заказа — не более одного отзыва на каждый объект. |

---

## FK-ограничения

| Таблица | Столбцы | → Таблица | BR | Обоснование |
|---|---|---|---|---|
| `client_address` | `client_id` | `client (client_id)` | BR-2.4 | Адрес привязывается к существующему клиенту. `ON DELETE CASCADE` — связь не живёт без клиента, адрес остаётся (BR-3.5). |
| `client_address` | `address_id` | `address (address_id)` | BR-2.4, BR-3.5 | Связь с существующим адресом; адрес нельзя удалить, пока он привязан. |
| `restaurant` | `address_id` | `address (address_id)` | BR-3.3, BR-3.5 | У ресторана ровно один адрес (`NOT NULL` + UNIQUE); адрес не удаляется. |
| `product` | `restaurant_id` | `restaurant (restaurant_id)` | BR-5.1 | Блюдо принадлежит ровно одному ресторану. |
| `product` | `product_category_id` | `product_category (product_category_id)` | BR-5.1, BR-5.7 | Блюдо принадлежит ровно одной категории из справочника. |
| `courier_pay` | `courier_id` | `courier (courier_id)` | BR-10.2 | Выплата начисляется существующему курьеру. |
| `order` | `client_id` | `client (client_id)` | BR-7.1, BR-7.2 | Заказ оформляет один клиент. |
| `order` | `restaurant_id` | `restaurant (restaurant_id)` | BR-7.2 | Заказ привязан к одному ресторану. |
| `order` | `courier_id` | `courier (courier_id)` | BR-7.5, BR-1.3 | Доставку выполняет курьер; самовывоза нет. |
| `order` | `address_id` | `address (address_id)` | BR-7.4, BR-3.5 | Доставка по одному адресу; адрес с историей заказов не удаляется. |
| `order` | `(client_id, address_id)` | `client_address (client_id, address_id)` | BR-7.4 | Адрес доставки — один из адресов именно этого клиента (ловушка 2). |
| `order_structure` | `order_id` | `order (order_id)` | BR-7.14 | Позиция принадлежит заказу. `ON DELETE CASCADE` — позиция не существует без заказа. |
| `order_structure` | `product_id` | `product (product_id)` | BR-7.14 | Позиция — существующее блюдо. Блюдо из заказов нельзя удалить (история). |
| `payment` | `order_id` | `order (order_id)` | BR-8.1 | Попытка оплаты относится к заказу. |
| `payment` | `(order_id, amount)` | `order (order_id, total_amount)` | BR-8.4 | Сумма попытки равна общей сумме заказа. `ON UPDATE CASCADE` — при изменении состава/суммы заказа сумма попыток обновляется автоматически. |
| `review` | `client_id` | `client (client_id)` | BR-9.1 | Отзыв оставляет клиент. |
| `review` | `order_id` | `order (order_id)` | BR-9.2 | Отзыв всегда связан с конкретным заказом. |
| `review` | `(order_id, client_id)` | `order (order_id, client_id)` | BR-9.2 | Отзыв к заказу оставляет только клиент, оформивший этот заказ. |

Итого 18 FK: 15 из ERD + 3 составных.

---

## Триггеры целостности

`db/schema/04_integrity_triggers.sql`. Используются только там, где декларативное ограничение невозможно или потребовало бы нарушить 3НФ.

| Триггер | Таблица / событие | BR | Что проверяет |
|---|---|---|---|
| `order_structure_integrity_trg` | `order_structure` BEFORE INSERT/UPDATE/DELETE | BR-7.3, BR-9.2 | Блюдо из ресторана заказа; нельзя удалить/изменить позицию, на блюдо из которой есть отзыв. |
| `order_restaurant_guard_trg` | `"order"` BEFORE UPDATE OF `restaurant_id` | BR-7.3, BR-9.2 | Нельзя сменить ресторан у заказа с позициями или с отзывом на ресторан. |
| `product_restaurant_guard_trg` | `product` BEFORE UPDATE OF `restaurant_id` | BR-5.1, BR-7.3 | Нельзя перенести в другой ресторан блюдо, которое уже есть в заказах. |
| `review_entity_check_trg` | `review` BEFORE INSERT/UPDATE | BR-9.1, BR-9.2 | `'блюдо'` — есть в позициях заказа; `'ресторан'` — ресторан заказа. |
| `order_pay_status_enforce_trg` | `"order"` BEFORE INSERT / UPDATE OF `pay_status` | BR-8.7 | `pay_status` всегда равен вычисленному по попыткам; вручную выставить несогласованное значение нельзя. |
| `payment_sync_order_pay_status_trg` | `payment` AFTER INSERT/UPDATE/DELETE | BR-8.7 | Пересчитывает `order.pay_status` при любом изменении попыток. |

Ошибки триггеров выдаются с SQLSTATE `check_violation` / `foreign_key_violation` и подсказкой (HINT) со ссылкой на правило.

---

## NOT NULL (только бизнес-обязательные)

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| `order` | `courier_id` | BR-1.3, BR-7.5 | Самовывоза нет, каждый заказ доставляет курьер. Курьер назначается при создании заказа. |
| `order` | `address_id` | BR-1.3, BR-7.4 | Все заказы доставляются по адресу. |
| `order` | `description` | BR-11.3 | BR не разрешают пустое значение, значит поле обязательно. |
| `restaurant` | `address_id` | BR-3.3 | У ресторана *ровно один* адрес — не «ноль или один». |
| `restaurant` | `work_start`, `work_end` | BR-4.4 | Без обоих значений график работы и CHECK `work_end > work_start` не имеют смысла. |
| `courier` | `hire_date` | BR-6.1 | Дата найма есть у каждого курьера (в отличие от даты увольнения). |
| `courier` | `coefficient` | BR-6.4, BR-6.5 | Коэффициент есть всегда: у нового курьера — 0.1. |
| `payment` | `amount`, `payment_type`, `transaction_ref`, `transaction_timestamp`, `status` | BR-8.2 | Каждая попытка оплаты *имеет* все эти атрибуты. |
| `review` | `entity_id`, `entity_type` | BR-9.1, BR-9.2 | Отзыв всегда на конкретный объект. |
| `"order"` | `pay_status` | BR-7.8, BR-8.7 | Статус оплаты есть у каждого заказа (до первой попытки — `'ожидает'`). |

---

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| `address` | `apartment_office` | BR-3.2, BR-11.3 | Частные дома и отдельные входы — указывать нечего. |
| `courier` | `dismissal_date` | BR-6.3, BR-11.3 | У работающего курьера даты увольнения нет. Для уволенного — обязательна (CHECK). |
| `order` | `delivery_timestamp` | BR-7.12, BR-11.3 | Пока заказ не доставлен, времени окончания доставки нет. Для доставленного — обязательно (CHECK). |
| `product` | `photo_url` | BR-5.6, BR-11.3 | Фотография блюда необязательна. |
| `review` | `photo_url` | BR-9.3, BR-11.3 | Фотография в отзыве необязательна. |
| `product` | `rating` | BR-9.7 | Если отзывов на блюдо нет, рейтинг = `NULL`. |
| `restaurant` | `rating` | BR-9.7 | Если отзывов на ресторан нет, рейтинг = `NULL`. |

---

## DEFAULT и GENERATED

| Таблица | Столбец | Что | Обоснование |
|---|---|---|---|
| все таблицы | `*_id` (PK) | `DEFAULT exts.uuid_generate_v4()` | BR-11.1: UUID генерируется на сервере. |
| `courier` | `coefficient` | `DEFAULT 0.1` | BR-6.5: изначальный коэффициент нового курьера. |
| `courier` | `status` | `DEFAULT 'свободен'` | Новый курьер ещё не взял заказ. |
| `restaurant` | `status` | `DEFAULT 'активен'` | Новый партнёр подключается активным. |
| `product` | `status` | `DEFAULT 'доступно'` | Новое блюдо доступно для заказа. |
| `order` | `status` | `DEFAULT 'создан'` | Первый статус жизненного цикла заказа (BR-7.7). |
| `order` | `pay_status` | `DEFAULT 'ожидает'` + триггер | До первой попытки оплаты успешных нет (BR-8.7). Фактическое значение всегда пересчитывает триггер. |
| `order` | `order_timestamp` | `DEFAULT localtimestamp` | BR-7.1, BR-11.2: время создания — время сервера без часового пояса. |
| `payment` | `transaction_timestamp` | `DEFAULT localtimestamp` | BR-8.2, BR-11.2. |
| `payment` | `status` | `DEFAULT 'в_обработке'` | Новая попытка ещё не обработана провайдером. |
| `review` | `review_timestamp` | `DEFAULT localtimestamp` | BR-9.3, BR-11.2. |
| `order` | `commission` | `GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED` | BR-1.4, BR-7.10: комиссия — ровно 10% от стоимости блюд, округление до копеек. |
| `order` | `total_amount` | `GENERATED ALWAYS AS (order_amount + round(order_amount * 0.10, 2)) STORED` | BR-7.10: общая сумма = сумма без комиссии + комиссия. Выражение повторено, т. к. генерируемый столбец не может ссылаться на другой генерируемый. |

Почему `GENERATED`, а не обычные поля с `CHECK (commission = round(order_amount * 0.10, 2))`: при обычных полях клиентский код обязан сам считать и передавать оба значения, и любая ошибка отклоняется только CHECK-ом. `GENERATED STORED` вычисляет значения в БД, разойтись с `order_amount` они не могут, а записать их вручную нельзя. `STORED` (а не вычисление в представлении) — потому что по `total_amount` есть ограничение `>= 1000`, на нём строится составной FK из `payment`, и его читают отчёты FOOD-106 и FOOD-108.

---

## Правила, которые схема не гарантирует (и почему)

| BR | Правило | Почему не в схеме |
|---|---|---|
| BR-6.6 | Хотя бы один активный курьер | Само правило говорит: проверяется в `insert_test_data`, на уровне схемы не гарантируется. |
| BR-7.14 | В заказе хотя бы одна позиция | Циклическая зависимость: позиция не вставляется без заказа, а заказ без позиции. Потребовался бы отложенный constraint-триггер, и любая вставка заказа без позиций в той же транзакции падала бы. Обеспечивается генератором (FOOD-102). |
| BR-8.1 | *Ровно* одна успешная попытка | Схема гарантирует «не больше одной» (частичный UNIQUE). «Хотя бы одна» в схеме невозможна: у неоплаченного заказа попытки ещё в обработке или с ошибкой (BR-8.7 допускает `'ожидает'` и `'ошибка'`). |
| BR-7.10 | `order_amount` = стоимость блюд | Цена блюда (`product.price`) может меняться, а сумма заказа фиксируется в момент оформления. Сверка с текущими ценами исказила бы историю. Генератор считает `order_amount` по позициям. |

---

## Нормализация (3НФ)

```
1НФ: все атрибуты атомарны. Адрес разбит на улицу, дом, квартиру (BR-3.1); у каждой
     таблицы есть PK; повторяющихся групп нет (позиции заказа, адреса клиента, попытки
     оплаты, выплаты — отдельные таблицы).

2НФ: в таблицах с составным PK неключевые атрибуты зависят от всего ключа:
     - order_structure (order_id, product_id) → quantity: количество — свойство
       конкретной позиции, не заказа и не блюда. Поэтому restaurant_id сюда НЕ
       добавлен (он зависел бы только от order_id — см. ловушку 3).
     - courier_pay (courier_id, year, month) → amount, coefficient_used: выплата и
       применённый коэффициент — за конкретный месяц конкретного курьера.
       coefficient_used не дублирует courier.coefficient: тот меняется каждый месяц,
       а здесь — исторический коэффициент того месяца (BR-10.2).
     - client_address — только ключ.

3НФ: транзитивных зависимостей нет: все неключевые атрибуты описывают сущность
     своей таблицы, ссылки на другие сущности — только через FK. Категория вынесена
     в справочник product_category (BR-5.7); адрес — в address, общий для клиентов,
     ресторанов и заказов.

Особые случаи:
- order.commission = 10% от order_amount — вычисляемое. GENERATED ALWAYS ... STORED:
  формально зависит от order_amount, но значение вычисляет СУБД, записать его вручную
  и рассинхронизировать нельзя — аномалий обновления нет. Хранится, потому что это
  финансовый факт заказа, по которому считается зарплата курьеров (BR-10.2).
- order.total_amount = order_amount + commission — так же GENERATED STORED. Хранится
  ради CHECK >= 1000 (BR-1.8), составного FK из payment (BR-8.4) и отчётов.
- product.rating и restaurant.rating — агрегаты AVG(review.rating), поддерживаются
  триггером rating_change (FOOD-105). Осознанная денормализация: рейтинг читается при
  каждом показе меню/каталога, а меняется только при изменении отзывов; считать AVG
  по review на каждый показ дорого. Триггер пересчитывает на любое изменение отзыва
  (BR-9.7), поэтому значение всегда согласовано.
- order.pay_status — агрегат по payment (BR-8.7). Та же логика: поддерживается
  триггерами, вручную рассинхронизировать нельзя (значение всегда пересчитывается).
- payment.amount равен order.total_amount (BR-8.4). Атрибут попытки по BR-8.2; его
  согласованность обеспечивает составной FK (order_id, amount) → order(order_id,
  total_amount) с ON UPDATE CASCADE — разойтись значения не могут.
- review.client_id определяется через order_id (клиент заказа). Столбец задан ERD;
  его согласованность обеспечивает составной FK (order_id, client_id) → order.
- review.entity_id + entity_type — полиморфизм. Не нарушает 3НФ: пара — это атрибут
  «на что отзыв», зависит только от review_id. Валидность ссылки — триггер (ловушка 4).
```
