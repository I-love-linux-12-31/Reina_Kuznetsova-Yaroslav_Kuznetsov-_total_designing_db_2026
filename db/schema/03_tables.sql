-- FOOD-101. Таблицы, ключи и ограничения целостности

set search_path to kuznetsova_food, exts;


-- address — физический адрес (BR-3.1 .. BR-3.5)
create table address (
    address_id       uuid         not null default exts.uuid_generate_v4(),
    street           varchar(100) not null,
    house_number     varchar(10)  not null,
    apartment_office varchar(10),                       -- BR-3.2: может отсутствовать

    constraint address_pk primary key (address_id),
    constraint address_street_ck           check (btrim(street) <> ''),
    constraint address_house_number_ck     check (btrim(house_number) <> ''),
    constraint address_apartment_office_ck check (btrim(apartment_office) <> ''),
    -- один физический адрес = одна строка (BR-3.3, BR-2.5)
    constraint address_street_house_apartment_uq
        unique nulls not distinct (street, house_number, apartment_office)
);

comment on table  address                  is 'Физический адрес (BR-3.1)';
comment on column address.apartment_office is 'Квартира/офис; NULL — частный дом/отдельный вход (BR-3.2)';


-- client — клиент (BR-2.1 .. BR-2.6)
create table client (
    client_id    uuid        not null default exts.uuid_generate_v4(),
    login        varchar(50) not null,
    password     char(32)    not null,                  -- MD5 в hex (BR-2.3)
    phone_number varchar(16) not null,                  -- E.164: +<код страны><номер>

    constraint client_pk primary key (client_id),
    constraint client_login_uq        unique (login),
    constraint client_phone_number_uq unique (phone_number),
    constraint client_login_ck        check (btrim(login) <> ''),
    constraint client_password_ck     check (password ~ '^[0-9a-f]{32}$'),
    constraint client_phone_number_ck check (phone_number ~ '^\+[1-9][0-9]{6,14}$')
);

comment on table  client              is 'Клиент; ФИО не хранится (BR-2.6)';
comment on column client.password     is 'MD5-хэш пароля, 32 hex-символа (BR-2.3)';
comment on column client.phone_number is 'Телефон в формате E.164: +, код страны, номер; 7..15 цифр (BR-2.1, BR-2.2)';


-- client_address — связь M:N клиент ↔ адрес (BR-2.4, BR-2.5)
create table client_address (
    client_id  uuid not null,
    address_id uuid not null,

    -- BR-2.5: один адрес привязывается к клиенту не более одного раза
    constraint client_address_pk primary key (client_id, address_id),
    constraint client_address_client_id_fk
        foreign key (client_id) references client (client_id)
        on delete cascade,                               -- связь уходит вместе с клиентом,
    constraint client_address_address_id_fk              -- сам адрес остаётся (BR-3.5)
        foreign key (address_id) references address (address_id)
);

create index client_address_address_id_idx on client_address (address_id);

comment on table client_address is 'Адреса доставки клиента, M:N (BR-2.4)';


-- restaurant — ресторан-партнёр (BR-3.3, BR-4.1 .. BR-4.5)
create table restaurant (
    restaurant_id   uuid              not null default exts.uuid_generate_v4(),
    restaurant_name varchar(150)      not null,
    address_id      uuid              not null,
    description     text              not null,
    work_start      time              not null,
    work_end        time              not null,
    company_details text              not null,
    rating          numeric(3,2),                       -- NULL, пока нет отзывов (BR-9.7)
    status          restaurant_status not null default 'активен',

    constraint restaurant_pk primary key (restaurant_id),
    constraint restaurant_address_id_uq unique (address_id),
    constraint restaurant_address_id_fk
        foreign key (address_id) references address (address_id),
    constraint restaurant_name_ck            check (btrim(restaurant_name) <> ''),
    constraint restaurant_description_ck     check (btrim(description) <> ''),
    constraint restaurant_company_details_ck check (btrim(company_details) <> ''),
    constraint restaurant_work_time_ck       check (work_end > work_start),
    constraint restaurant_rating_ck          check (rating between 0 and 5)
);

comment on table  restaurant                 is 'Ресторан-партнёр (BR-4.1)';
comment on column restaurant.company_details is 'Реквизиты: ИНН, ОГРН, р/с; история не ведётся (BR-4.5)';
comment on column restaurant.rating          is 'Агрегат AVG(review.rating), поддерживается триггером rating_change (BR-9.6)';


-- courier — курьер (BR-6.1 .. BR-6.5)
create table courier (
    courier_id     uuid           not null default exts.uuid_generate_v4(),
    fio            varchar(150)   not null,
    phone_number   varchar(16)    not null,              -- E.164, как у клиента
    status         courier_status not null default 'свободен',
    hire_date      date           not null,
    dismissal_date date,                                 -- NULL у работающего (BR-6.3)
    coefficient    numeric(3,2)   not null default 0.1,  -- BR-6.5

    constraint courier_pk primary key (courier_id),
    constraint courier_fio_ck            check (btrim(fio) <> ''),
    constraint courier_phone_number_ck   check (phone_number ~ '^\+[1-9][0-9]{6,14}$'),
    constraint courier_dismissal_ck      check (status <> 'уволен' or dismissal_date is not null),
    constraint courier_dismissal_date_ck check (dismissal_date >= hire_date),
    constraint courier_coefficient_ck    check (coefficient between 0.1 and 0.5)
);

comment on table  courier              is 'Курьер — сотрудник сервиса (BR-6.1)';
comment on column courier.coefficient  is 'Коэффициент зарплаты на текущий месяц, 0.1..0.5 (BR-6.4)';
comment on column courier.phone_number is 'Телефон в формате E.164: +, код страны, номер; 7..15 цифр (BR-6.1)';


-- courier_pay — ежемесячная выплата курьеру (BR-10.1 .. BR-10.4)
create table courier_pay (
    courier_id       uuid          not null,
    year             smallint      not null,
    month            smallint      not null,
    amount           numeric(12,2) not null,
    coefficient_used numeric(3,2)  not null,

    -- BR-10.3: одна запись на курьера за месяц
    constraint courier_pay_pk primary key (courier_id, year, month),
    constraint courier_pay_courier_id_fk
        foreign key (courier_id) references courier (courier_id),
    constraint courier_pay_year_ck             check (year between 2000 and 2100),
    constraint courier_pay_month_ck            check (month between 1 and 12),
    constraint courier_pay_amount_ck           check (amount >= 0),
    constraint courier_pay_coefficient_used_ck check (coefficient_used between 0.1 and 0.5)
);

comment on table  courier_pay                  is 'Выплата курьеру за месяц (BR-10.2)';
comment on column courier_pay.coefficient_used is 'Коэффициент, действовавший в этом месяце (BR-10.2)';


-- product_category — справочник категорий (BR-5.7)
create table product_category (
    product_category_id   uuid         not null default exts.uuid_generate_v4(),
    product_category_name varchar(100) not null,

    constraint product_category_pk primary key (product_category_id),
    constraint product_category_name_uq unique (product_category_name),
    constraint product_category_name_ck check (btrim(product_category_name) <> '')
);

comment on table product_category is 'Справочник категорий блюд (BR-5.7)';


-- product — блюдо (BR-5.1 .. BR-5.6)
create table product (
    product_id          uuid           not null default exts.uuid_generate_v4(),
    product_name        varchar(150)   not null,
    product_category_id uuid           not null,
    price               numeric(10,2)  not null,
    restaurant_id       uuid           not null,
    photo_url           text,                            -- BR-5.6: необязательна
    rating              numeric(3,2),                    -- NULL, пока нет отзывов (BR-9.7)
    status              product_status not null default 'доступно',
    description         text           not null,

    constraint product_pk primary key (product_id),
    constraint product_product_category_id_fk
        foreign key (product_category_id) references product_category (product_category_id),
    constraint product_restaurant_id_fk
        foreign key (restaurant_id) references restaurant (restaurant_id),
    constraint product_name_ck        check (btrim(product_name) <> ''),
    constraint product_description_ck check (btrim(description) <> ''),
    constraint product_price_ck       check (price >= 0),
    constraint product_rating_ck      check (rating between 0 and 5),
    constraint product_photo_url_ck   check (photo_url ~* '^https?://\S+$')
);

create index product_restaurant_id_idx       on product (restaurant_id);
create index product_product_category_id_idx on product (product_category_id);

comment on table  product        is 'Блюдо (BR-5.1, BR-5.2)';
comment on column product.rating is 'Агрегат AVG(review.rating), поддерживается триггером rating_change (BR-9.6)';


-- "order" — заказ (BR-7.1 .. BR-7.13)
-- Имя оставлено как в ERD и взято в кавычки (BR-13.1).
create table "order" (
    order_id           uuid             not null default exts.uuid_generate_v4(),
    courier_id         uuid             not null,
    client_id          uuid             not null,
    address_id         uuid             not null,
    restaurant_id      uuid             not null,
    order_timestamp    timestamp        not null default localtimestamp,
    delivery_timestamp timestamp,                        -- NULL, пока не доставлен (BR-7.12)
    order_amount       numeric(12,2)    not null,        -- стоимость блюд
    commission         numeric(12,2)    not null         -- 10% (BR-1.4, BR-7.10)
        generated always as (round(order_amount * 0.10, 2)) stored,
    total_amount       numeric(12,2)    not null         -- блюда + комиссия (BR-7.10)
        generated always as (order_amount + round(order_amount * 0.10, 2)) stored,
    status             order_status     not null default 'создан',
    pay_status         order_pay_status not null default 'ожидает',
    description        text             not null,

    constraint order_pk primary key (order_id),

    -- целевые ключи для составных FK из review и payment
    constraint order_order_id_client_id_uq    unique (order_id, client_id),
    constraint order_order_id_total_amount_uq unique (order_id, total_amount),

    constraint order_courier_id_fk
        foreign key (courier_id) references courier (courier_id),
    constraint order_client_id_fk
        foreign key (client_id) references client (client_id),
    constraint order_address_id_fk
        foreign key (address_id) references address (address_id),
    constraint order_restaurant_id_fk
        foreign key (restaurant_id) references restaurant (restaurant_id),
    -- BR-7.4: адрес доставки — один из адресов этого клиента
    constraint order_client_address_fk
        foreign key (client_id, address_id) references client_address (client_id, address_id),

    constraint order_description_ck     check (btrim(description) <> ''),
    constraint order_order_amount_ck    check (order_amount >= 0),
    constraint order_total_amount_ck    check (total_amount >= 1000),
    constraint order_delivery_ck        check (status <> 'доставлен' or delivery_timestamp is not null),
    constraint order_delivery_time_ck   check (delivery_timestamp >= order_timestamp)
);

create index order_courier_id_idx     on "order" (courier_id);
create index order_client_address_idx on "order" (client_id, address_id);
create index order_address_id_idx     on "order" (address_id);
create index order_restaurant_id_idx  on "order" (restaurant_id);

comment on table  "order"            is 'Заказ (BR-7.1)';
comment on column "order".commission is 'GENERATED: round(order_amount * 0.10, 2) (BR-1.4)';
comment on column "order".total_amount is 'GENERATED: order_amount + commission (BR-7.10)';
comment on column "order".pay_status is 'Агрегат по payment, поддерживается триггером (BR-8.7)';


-- order_structure — позиция заказа (BR-7.14 .. BR-7.16)
create table order_structure (
    order_id   uuid         not null,
    product_id uuid         not null,
    quantity   numeric(8,3) not null,

    -- BR-7.16: блюдо встречается в заказе один раз
    constraint order_structure_pk primary key (order_id, product_id),
    constraint order_structure_order_id_fk
        foreign key (order_id) references "order" (order_id)
        on delete cascade,                               -- позиция — часть заказа
    constraint order_structure_product_id_fk
        foreign key (product_id) references product (product_id),
    constraint order_structure_quantity_ck check (quantity > 0)
);

create index order_structure_product_id_idx on order_structure (product_id);

comment on table  order_structure          is 'Позиция заказа: блюдо и количество (BR-7.14)';
comment on column order_structure.quantity is 'Положительное, может быть дробным (BR-7.15)';


-- payment — попытка оплаты заказа (BR-8.1 .. BR-8.6)
create table payment (
    payment_id            uuid           not null default exts.uuid_generate_v4(),
    order_id              uuid           not null,
    payment_type          payment_type   not null,
    amount                numeric(12,2)  not null,
    transaction_ref       varchar(64)    not null,       -- внешний ID транзакции (BR-8.3)
    transaction_timestamp timestamp      not null default localtimestamp,
    status                payment_status not null default 'в_обработке',

    constraint payment_pk primary key (payment_id),
    constraint payment_transaction_ref_uq unique (transaction_ref),
    constraint payment_order_id_fk
        foreign key (order_id) references "order" (order_id),
    -- BR-8.4: сумма попытки = общая сумма заказа (и следует за её изменением)
    constraint payment_order_amount_fk
        foreign key (order_id, amount) references "order" (order_id, total_amount)
        on update cascade,
    constraint payment_transaction_ref_ck check (btrim(transaction_ref) <> '')
);

-- BR-8.1: не более одной успешной попытки на заказ
create unique index payment_order_id_success_uq
    on payment (order_id)
    where status = 'успех';

create index payment_order_id_idx on payment (order_id);

comment on table  payment                 is 'Попытка оплаты заказа (BR-8.1, BR-8.2)';
comment on column payment.transaction_ref is 'Внешний идентификатор транзакции платёжного провайдера (BR-8.3, BR-8.5)';


-- review — отзыв на блюдо / ресторан / заказ (BR-9.1 .. BR-9.5)
-- entity_id — полиморфная ссылка, валидируется триггером (см. 04_*.sql)
create table review (
    review_id        uuid               not null default exts.uuid_generate_v4(),
    client_id        uuid               not null,
    review_timestamp timestamp          not null default localtimestamp,
    entity_id        uuid               not null,
    entity_type      review_entity_type not null,
    order_id         uuid               not null,
    description      text               not null,
    photo_url        text,                               -- BR-9.3: необязательна
    rating           smallint           not null,

    constraint review_pk primary key (review_id),
    -- BR-9.5: не более одного отзыва на объект в рамках заказа
    constraint review_order_entity_uq unique (order_id, entity_type, entity_id),
    constraint review_client_id_fk
        foreign key (client_id) references client (client_id),
    constraint review_order_id_fk
        foreign key (order_id) references "order" (order_id),
    -- BR-9.2: отзыв оставляет тот клиент, который оформил заказ
    constraint review_order_client_fk
        foreign key (order_id, client_id) references "order" (order_id, client_id),
    constraint review_description_ck check (btrim(description) <> ''),
    constraint review_photo_url_ck   check (btrim(photo_url) <> ''),
    constraint review_rating_ck      check (rating between 1 and 5),
    -- BR-9.1, BR-9.2: отзыв на заказ ссылается на свой же заказ
    constraint review_order_entity_ck check (entity_type <> 'заказ' or entity_id = order_id)
);

create index review_entity_idx    on review (entity_type, entity_id);
create index review_client_id_idx on review (client_id);
-- поиск по order_id покрывает review_order_entity_uq (order_id — первый столбец)

comment on table  review           is 'Отзыв клиента (BR-9.1)';
comment on column review.entity_id is 'product_id / restaurant_id / order_id в зависимости от entity_type';
