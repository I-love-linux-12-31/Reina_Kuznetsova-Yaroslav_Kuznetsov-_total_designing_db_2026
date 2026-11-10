-- FOOD-104. Добавление блюда add_product(...)
--
-- Принимает все атрибуты product, кроме product_id (он берётся из DEFAULT
-- exts.uuid_generate_v4(), BR-11.1).
-- Все бизнес-правила проверяются до вставки, чтобы ошибка была понятной
-- (сообщение + DETAIL + HINT со ссылкой на BR). Ограничения таблицы
-- остаются последним рубежом: если правило обойти (например, удалить
-- ресторан параллельной транзакцией), INSERT всё равно упадёт на FK/CHECK.


set search_path to kuznetsova_food, exts;


create or replace procedure add_product(
    p_name                varchar,
    p_product_category_id uuid,
    p_price               numeric,
    p_restaurant_id       uuid,
    p_description         text,
    p_photo_url           text           default null,
    p_rating              numeric        default null,
    p_status              product_status default 'доступно'
)
language plpgsql
set search_path to kuznetsova_food, exts
as $$
declare
    v_product_id uuid;
begin
    -- обязательные значения (BR-5.1, BR-5.2, BR-11.3)
    if p_name is null or btrim(p_name) = '' then
        raise exception 'add_product: не задано название блюда'
            using errcode = 'not_null_violation',
                  hint    = 'BR-5.2, BR-11.3: название блюда обязательно и не может быть пустой строкой.';
    end if;

    if length(p_name) > 150 then
        raise exception 'add_product: название блюда длиннее 150 символов (%)', length(p_name)
            using errcode = 'string_data_right_truncation',
                  hint    = 'product.product_name — varchar(150).';
    end if;

    if p_description is null or btrim(p_description) = '' then
        raise exception 'add_product: не задано описание блюда'
            using errcode = 'not_null_violation',
                  hint    = 'BR-5.2, BR-11.3: описание блюда обязательно и не может быть пустой строкой.';
    end if;

    if p_status is null then
        raise exception 'add_product: не задан статус блюда'
            using errcode = 'not_null_violation',
                  hint    = 'BR-5.5: статус — одно из значений product_status; по умолчанию ''доступно''.';
    end if;

    -- цена (BR-5.3) и точность numeric(10,2)
    if p_price is null then
        raise exception 'add_product: не задана цена блюда'
            using errcode = 'not_null_violation',
                  hint    = 'BR-5.2: у блюда есть цена.';
    end if;

    if p_price < 0 then
        raise exception 'add_product: цена блюда не может быть отрицательной (передано %)', p_price
            using errcode = 'check_violation',
                  hint    = 'BR-5.3: цена блюда неотрицательна.';
    end if;

    if round(p_price, 2) >= 1e8 then
        raise exception 'add_product: цена блюда слишком большая (передано %)', p_price
            using errcode = 'numeric_value_out_of_range',
                  hint    = 'product.price — numeric(10,2): не больше 99 999 999.99.';
    end if;

    -- рейтинг (BR-5.4); NULL — «отзывов ещё нет» (BR-9.7)
    if p_rating is not null and (p_rating < 0 or p_rating > 5) then
        raise exception 'add_product: рейтинг блюда должен быть от 0 до 5 (передано %)', p_rating
            using errcode = 'check_violation',
                  hint    = 'BR-5.4: рейтинг блюда — от 0 до 5; NULL, если отзывов нет (BR-9.7).';
    end if;

    -- фото — ссылка (BR-5.6), необязательна
    if p_photo_url is not null and p_photo_url !~* '^https?://\S+$' then
        raise exception 'add_product: фотография должна быть ссылкой http(s)://… (передано «%»)', p_photo_url
            using errcode = 'check_violation',
                  hint    = 'BR-5.6: фотография — URL; если фото нет, передайте NULL.';
    end if;

    -- ссылки на ресторан и категорию (BR-5.1, BR-5.7)
    if p_restaurant_id is null then
        raise exception 'add_product: не задан ресторан блюда'
            using errcode = 'not_null_violation',
                  hint    = 'BR-5.1: блюдо принадлежит ровно одному ресторану.';
    end if;

    if not exists (select 1 from restaurant r where r.restaurant_id = p_restaurant_id) then
        raise exception 'add_product: ресторан % не существует', p_restaurant_id
            using errcode = 'foreign_key_violation',
                  hint    = 'BR-5.1: блюдо можно добавить только существующему ресторану.';
    end if;

    if p_product_category_id is null then
        raise exception 'add_product: не задана категория блюда'
            using errcode = 'not_null_violation',
                  hint    = 'BR-5.1: блюдо принадлежит ровно одной категории.';
    end if;

    if not exists (select 1
                     from product_category pc
                    where pc.product_category_id = p_product_category_id)
    then
        raise exception 'add_product: категория блюд % не существует', p_product_category_id
            using errcode = 'foreign_key_violation',
                  hint    = 'BR-5.7: категория выбирается из справочника product_category.';
    end if;

    -- product_id — DEFAULT exts.uuid_generate_v4() (BR-11.1)
    insert into product (product_name, product_category_id, price, restaurant_id,
                         photo_url, rating, status, description)
    values (p_name, p_product_category_id, p_price, p_restaurant_id,
            p_photo_url, p_rating, p_status, p_description)
    returning product_id into v_product_id;

    raise notice 'add_product: добавлено блюдо % («%»)', v_product_id, p_name;
end;
$$;

comment on procedure add_product(varchar, uuid, numeric, uuid, text, text, numeric, product_status) is
    'FOOD-104: добавляет блюдо; product_id генерируется DEFAULT exts.uuid_generate_v4()';
