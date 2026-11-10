-- FOOD-102. Генератор тестовых данных insert_test_data(value)
--
-- Распределение строк (BR-11.7):
--   value * 1: client, courier, product_category, restaurant;
--   value * 5: address (value - под рестораны, value * 4 - под клиентов),
--              product, "order", review, payment;
--   client_address, order_structure - сколько нужно для связности;
--   courier_pay - каждый курьер * каждый из последних 6 месяцев (BR-10.7).
--
-- Повторный вызов без очистки добавляет ещё один независимый «пакет» данных:
-- заказы, отзывы и выплаты пакета ссылаются только на клиентов, рестораны,
-- блюда и курьеров этого же пакета. Поэтому ранее сгенерированные выплаты
-- и рейтинги не теряют согласованности. Уникальные значения (логин, телефон
-- клиента, адрес, название категории) подбираются повторной попыткой
-- через ON CONFLICT DO NOTHING.


set search_path to kuznetsova_food, exts;


create or replace procedure insert_test_data(value int)
language plpgsql
set search_path to kuznetsova_food, exts
as $$
declare
    c_max_attempts constant int       := 100;   -- попыток подобрать уникальное значение
    c_min_amount   constant numeric   := 910;   -- 910 + 10% = 1001 >= 1000 (BR-1.8, BR-7.11)
    c_delivered    constant numeric   := 0.7;   -- доля доставленных заказов
    c_now          constant timestamp := date_trunc('second', localtimestamp);
    -- окно данных: текущий месяц и 5 предыдущих (6 месяцев, как у courier_pay)
    c_win_start    constant date      := (date_trunc('month', current_date) - interval '5 months')::date;

    -- словари для «живых» строк
    v_streets      text[] := array['ул. Ленина', 'ул. Пушкина', 'пр. Мира', 'ул. Гагарина',
                                   'ул. Садовая', 'ул. Советская', 'ул. Молодёжная', 'ул. Школьная',
                                   'ул. Лесная', 'ул. Центральная', 'ул. Набережная', 'пер. Почтовый',
                                   'б-р Победы', 'ул. Зелёная', 'ул. Строителей'];
    v_house_suffix text[] := array['', '', '', '', 'А', 'Б', 'к1', 'к2', 'с1'];
    v_nicks        text[] := array['alex', 'maria', 'ivan', 'olga', 'dmitry', 'anna', 'sergey',
                                   'elena', 'max', 'kate', 'nikita', 'sofia', 'artem', 'daria'];
    v_categories_n text[] := array['Пицца', 'Суши', 'Роллы', 'Бургеры', 'Супы', 'Салаты', 'Десерты',
                                   'Напитки', 'Паста', 'Шаурма', 'Завтраки', 'Выпечка', 'Гриль', 'Вок',
                                   'Стейки', 'Веганское', 'Детское меню', 'Закуски', 'Морепродукты',
                                   'Пельмени'];
    v_rest_kind    text[] := array['Ресторан', 'Кафе', 'Бистро', 'Траттория', 'Пиццерия', 'Суши-бар',
                                   'Бургерная', 'Столовая', 'Чайхана', 'Гриль-бар'];
    v_rest_name    text[] := array['Огонёк', 'Берёзка', 'Сакура', 'Венеция', 'Тануки', 'Мангал',
                                   'Лагуна', 'Уют', 'Пряности', 'Восток', 'Старый город', 'Причал'];
    v_rest_desc    text[] := array['Домашняя кухня и большие порции',
                                   'Авторская кухня от шеф-повара',
                                   'Быстрые обеды для всей семьи',
                                   'Блюда на открытом огне',
                                   'Классика европейской кухни',
                                   'Паназиатская кухня и свежие роллы'];
    v_dish_adj     text[] := array['Классический', 'Острый', 'Домашний', 'Фирменный', 'Сырный',
                                   'Грибной', 'Овощной', 'Куриный', 'Мясной', 'Сливочный'];
    v_dish_noun    text[] := array['бургер', 'суп', 'салат', 'ролл', 'пирог', 'стейк', 'рамен',
                                   'плов', 'десерт', 'сэндвич', 'борщ', 'шашлык', 'лагман'];
    v_dish_desc    text[] := array['Готовится из свежих продуктов',
                                   'Хит продаж нашего ресторана',
                                   'Подаётся с соусом на выбор',
                                   'Порция 300 г',
                                   'Сезонное предложение',
                                   'Рецепт от шеф-повара'];
    v_order_desc   text[] := array['Позвонить за 10 минут до приезда', 'Без лука, пожалуйста',
                                   'Оставить у двери', 'Домофон не работает, позвонить',
                                   'Приборы на двоих', 'Без приборов', 'Нужна сдача с 5000',
                                   'Не звонить, ребёнок спит', 'Поднять на этаж', 'Без комментариев'];
    v_review_desc  text[] := array['Очень вкусно, спасибо!', 'Доставили быстро, всё горячее',
                                   'Порция могла быть больше', 'Курьер очень вежливый',
                                   'Немного остыло, но вкусно', 'Буду заказывать ещё', 'Всё отлично',
                                   'Слишком остро', 'Хорошее соотношение цены и качества',
                                   'Упаковка помялась'];
    v_surname      text[] := array['Иванов', 'Петров', 'Смирнов', 'Кузнецов', 'Попов', 'Соколов',
                                   'Лебедев', 'Козлов', 'Новиков', 'Морозов'];
    v_name_m       text[] := array['Александр', 'Дмитрий', 'Максим', 'Сергей', 'Андрей', 'Алексей',
                                   'Артём', 'Илья', 'Кирилл', 'Михаил'];
    v_name_f       text[] := array['Анна', 'Мария', 'Елена', 'Ольга', 'Наталья', 'Татьяна', 'Ирина',
                                   'Екатерина', 'Дарья', 'Софья'];
    v_patr         text[] := array['Александров', 'Дмитриев', 'Сергеев', 'Андреев', 'Алексеев',
                                   'Игорев', 'Олегов', 'Петров'];

    -- ID текущего пакета
    v_categories   uuid[] := '{}';
    v_addresses    uuid[] := '{}';   -- 1..value - под рестораны, остальные - под клиентов
    v_restaurants  uuid[] := '{}';
    v_couriers     uuid[] := '{}';
    v_hire         date[] := '{}';
    v_dismiss      date[] := '{}';
    v_clients      uuid[] := '{}';
    v_products     uuid[] := '{}';
    v_orders       uuid[] := '{}';

    v_id           uuid;
    v_try          int;
    i              int;
    j              int;
    k              int;

    -- курьер
    v_hire_date    date;
    v_dis_date     date;
    v_cour_status  courier_status;
    v_female       boolean;

    -- ресторан
    v_work_start   time;

    -- заказ
    v_client       uuid;
    v_address      uuid;
    v_restaurant   uuid;
    v_courier_idx  int;
    v_order_ts     timestamp;
    v_delivery_ts  timestamp;
    v_order_status order_status;
    v_pay_status   payment_status;
    v_items        int;
    v_pids         uuid[];
    v_prices       numeric[];
    v_qty          numeric[];
    v_amount       numeric;
    v_total        numeric;

    -- выплаты
    v_month        date;
    v_coef         numeric(3,2);
    v_cnt          bigint;
    v_commission   numeric;
begin
    if value is null or value < 1 then
        raise exception 'insert_test_data: value должен быть целым числом >= 1, передано %', value
            using errcode = 'invalid_parameter_value';
    end if;


    -- 1. product_category (value). Название уникально (UNIQUE): при совпадении -
    --    случайный суффикс и повторная попытка.
    for i in 1..value loop
        v_try := 0;
        loop
            v_try := v_try + 1;
            insert into product_category (product_category_id, product_category_name)
            values (exts.uuid_generate_v4(),
                    v_categories_n[floor(random() * cardinality(v_categories_n))::int + 1]
                    || case when v_try > 1 then ' ' || substr(md5(random()::text), 1, 6) else '' end)
            on conflict do nothing
            returning product_category_id into v_id;

            exit when v_id is not null;
            if v_try >= c_max_attempts then
                raise exception 'insert_test_data: не удалось подобрать уникальное название категории';
            end if;
        end loop;
        v_categories := v_categories || v_id;
    end loop;


    -- 2. address (value * 5). Первые value - под рестораны (BR-11.7).
    --    (street, house_number, apartment_office) уникальны - повтор при совпадении.
    for i in 1..value * 5 loop
        v_try := 0;
        loop
            v_try := v_try + 1;
            insert into address (address_id, street, house_number, apartment_office)
            values (exts.uuid_generate_v4(),
                    v_streets[floor(random() * cardinality(v_streets))::int + 1],
                    (floor(random() * 150)::int + 1)::text
                        || v_house_suffix[floor(random() * cardinality(v_house_suffix))::int + 1],
                    case
                        when random() < 0.25 then null                                    -- BR-3.2
                        when i <= value      then 'оф. ' || (floor(random() * 50)::int + 1)
                        else                      (floor(random() * 300)::int + 1)::text
                    end)
            on conflict do nothing
            returning address_id into v_id;

            exit when v_id is not null;
            if v_try >= c_max_attempts then
                raise exception 'insert_test_data: не удалось подобрать уникальный адрес';
            end if;
        end loop;
        v_addresses := v_addresses || v_id;
    end loop;


    -- 3. restaurant (value): у каждого свой адрес из первых value (BR-3.3).
    --    work_start 06:00..12:00, work_end = start + 6ч..11ч59м <= 23:59 (BR-4.4).
    --    rating - после отзывов (шаг 10).
    for i in 1..value loop
        v_work_start := time '06:00' + floor(random() * 361)::int * interval '1 minute';

        insert into restaurant (restaurant_id, restaurant_name, address_id, description,
                                work_start, work_end, company_details, rating, status)
        values (exts.uuid_generate_v4(),
                v_rest_kind[floor(random() * cardinality(v_rest_kind))::int + 1]
                    || ' «' || v_rest_name[floor(random() * cardinality(v_rest_name))::int + 1] || '»',
                v_addresses[i],
                v_rest_desc[floor(random() * cardinality(v_rest_desc))::int + 1],
                v_work_start,
                v_work_start + interval '6 hours' + floor(random() * 360)::int * interval '1 minute',
                format('ИНН %s, ОГРН %s, р/с 40702810%s',
                       lpad(floor(random() * 1e10)::bigint::text, 10, '0'),
                       lpad(floor(random() * 1e13)::bigint::text, 13, '0'),
                       lpad(floor(random() * 1e12)::bigint::text, 12, '0')),
                null,
                (enum_range(null::restaurant_status))[
                    floor(random() * cardinality(enum_range(null::restaurant_status)))::int + 1])
        returning restaurant_id into v_id;

        v_restaurants := v_restaurants || v_id;
    end loop;


    -- 4. courier (value). Все наняты в первом месяце окна, чтобы выплаты были
    --    за каждый из 6 месяцев. Первый курьер нанят в первый день окна и
    --    никогда не уволен - гарантия BR-6.6 и курьер «по умолчанию» для заказов.
    --    Коэффициент - 0.1 (BR-6.5), итоговый проставляется на шаге 11.
    for i in 1..value loop
        v_hire_date := c_win_start + case when i = 1 then 0 else floor(random() * 28)::int end;

        if i > 1 and random() < 0.2 then
            v_cour_status := 'уволен';
            v_dis_date    := v_hire_date + floor(random() * (current_date - v_hire_date + 1))::int;  -- BR-6.3
        else
            v_cour_status := (array_remove(enum_range(null::courier_status), 'уволен'))[
                floor(random() * (cardinality(enum_range(null::courier_status)) - 1))::int + 1];
            v_dis_date    := null;
        end if;

        v_female := random() < 0.4;

        insert into courier (courier_id, fio, phone_number, status, hire_date, dismissal_date, coefficient)
        values (exts.uuid_generate_v4(),
                v_surname[floor(random() * cardinality(v_surname))::int + 1]
                    || case when v_female then 'а ' else ' ' end
                    || case when v_female
                            then v_name_f[floor(random() * cardinality(v_name_f))::int + 1]
                            else v_name_m[floor(random() * cardinality(v_name_m))::int + 1]
                       end
                    || ' ' || v_patr[floor(random() * cardinality(v_patr))::int + 1]
                    || case when v_female then 'на' else 'ич' end,
                '+79' || lpad(floor(random() * 1e9)::bigint::text, 9, '0'),
                v_cour_status,
                v_hire_date,
                v_dis_date,
                0.1)
        returning courier_id into v_id;

        v_couriers := v_couriers || v_id;
        v_hire     := v_hire || v_hire_date;
        v_dismiss  := array_append(v_dismiss, v_dis_date);
    end loop;


    -- 5. client (value). Логин и телефон уникальны (BR-2.2) - повтор при совпадении.
    --    Пароль - md5(random()::text) (BR-2.3).
    for i in 1..value loop
        v_try := 0;
        loop
            v_try := v_try + 1;
            insert into client (client_id, login, password, phone_number)
            values (exts.uuid_generate_v4(),
                    v_nicks[floor(random() * cardinality(v_nicks))::int + 1]
                        || '_' || substr(md5(random()::text), 1, floor(random() * 10)::int + 1),
                    md5(random()::text),
                    '+79' || lpad(floor(random() * 1e9)::bigint::text, 9, '0'))
            on conflict do nothing
            returning client_id into v_id;

            exit when v_id is not null;
            if v_try >= c_max_attempts then
                raise exception 'insert_test_data: не удалось подобрать уникальные логин/телефон клиента';
            end if;
        end loop;
        v_clients := v_clients || v_id;
    end loop;


    -- 6. client_address. Используются все value * 4 клиентских адреса:
    --    первые value - по одному каждому клиенту (у каждого есть хотя бы один адрес),
    --    остальные - случайным клиентам. Часть адресов дополнительно привязана ко
    --    второму клиенту (BR-2.4: общий адрес). Пара уникальна (PK, BR-2.5).
    for k in value + 1 .. value * 5 loop
        j := k - value;
        insert into client_address (client_id, address_id)
        values (case when j <= value then v_clients[j]
                     else v_clients[floor(random() * value)::int + 1] end,
                v_addresses[k]);

        if value > 1 and random() < 0.15 then
            insert into client_address (client_id, address_id)
            values (v_clients[floor(random() * value)::int + 1], v_addresses[k])
            on conflict do nothing;
        end if;
    end loop;


    -- 7. product (value * 5). Первые value - по одному каждому ресторану, чтобы
    --    в любом ресторане было что заказать. Цена > 0 (BR-5.3), фото - иногда NULL
    --    (BR-5.6), rating - после отзывов (шаг 10).
    for i in 1..value * 5 loop
        insert into product (product_id, product_name, product_category_id, price, restaurant_id,
                             photo_url, rating, status, description)
        values (exts.uuid_generate_v4(),
                v_dish_adj[floor(random() * cardinality(v_dish_adj))::int + 1]
                    || ' ' || v_dish_noun[floor(random() * cardinality(v_dish_noun))::int + 1],
                v_categories[floor(random() * value)::int + 1],
                50 + floor(random() * 1451),                                        -- 50..1500 ₽
                case when i <= value then v_restaurants[i]
                     else v_restaurants[floor(random() * value)::int + 1] end,
                case when random() < 0.3 then null
                     else 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' end,
                null,
                (enum_range(null::product_status))[
                    floor(random() * cardinality(enum_range(null::product_status)))::int + 1],
                v_dish_desc[floor(random() * cardinality(v_dish_desc))::int + 1])
        returning product_id into v_id;

        v_products := v_products || v_id;
    end loop;


    -- 8. "order" (value * 5) + order_structure + payment (по одной попытке на заказ).
    for i in 1..value * 5 loop
        v_client     := v_clients[floor(random() * value)::int + 1];
        v_restaurant := v_restaurants[floor(random() * value)::int + 1];

        -- BR-7.4: адрес доставки - один из адресов этого клиента
        -- (выборка по индексу PK client_address, несколько строк - не полный скан)
        select ca.address_id
          into v_address
          from client_address ca
         where ca.client_id = v_client
         order by random()
         limit 1;

        v_order_ts := date_trunc('second', c_win_start + random() * (c_now - c_win_start));

        v_order_status := case
                              when random() < c_delivered then 'доставлен'::order_status
                              else (enum_range(null::order_status))[
                                  floor(random() * cardinality(enum_range(null::order_status)))::int + 1]
                          end;

        -- BR-7.12, BR-7.13: время доставки только у доставленных, не раньше создания
        v_delivery_ts := case
                             when v_order_status = 'доставлен'
                             then least(v_order_ts + (15 + floor(random() * 106))::int * interval '1 minute', c_now)
                         end;

        -- курьер, работавший в день заказа; иначе - первый (всегда работает)
        v_courier_idx := 1;
        for j in 1..3 loop
            k := floor(random() * value)::int + 1;
            if v_order_ts::date between v_hire[k] and coalesce(v_dismiss[k], current_date) then
                v_courier_idx := k;
                exit;
            end if;
        end loop;

        -- позиции: 1..5 разных блюд ресторана заказа (BR-7.3, BR-7.16)
        v_items := floor(random() * 5)::int + 1;
        select array_agg(t.product_id), array_agg(t.price)
          into v_pids, v_prices
          from (select p.product_id, p.price
                  from product p
                 where p.restaurant_id = v_restaurant
                 order by random()
                 limit v_items) t;

        v_qty := '{}';
        for j in 1..cardinality(v_pids) loop
            v_qty := v_qty || case when random() < 0.15
                                   then (floor(random() * 4) + 1) * 0.5            -- 0.5..2.0 (BR-7.15)
                                   else floor(random() * 3) + 1                    -- 1..3
                              end::numeric;
        end loop;

        select round(sum(u.price * u.qty), 2) into v_amount
          from unnest(v_prices, v_qty) as u(price, qty);

        -- BR-1.8: добираем количество первой позиции до минимальной суммы
        if v_amount < c_min_amount then
            v_qty[1] := v_qty[1] + ceil((c_min_amount - v_amount) / v_prices[1]);
            select round(sum(u.price * u.qty), 2) into v_amount
              from unnest(v_prices, v_qty) as u(price, qty);
        end if;

        insert into "order" (order_id, courier_id, client_id, address_id, restaurant_id,
                             order_timestamp, delivery_timestamp, order_amount, status, description)
        values (exts.uuid_generate_v4(), v_couriers[v_courier_idx], v_client, v_address, v_restaurant,
                v_order_ts, v_delivery_ts, v_amount, v_order_status,
                v_order_desc[floor(random() * cardinality(v_order_desc))::int + 1])
        returning order_id, total_amount into v_id, v_total;

        v_orders := v_orders || v_id;

        insert into order_structure (order_id, product_id, quantity)
        select v_id, u.product_id, u.qty
          from unnest(v_pids, v_qty) as u(product_id, qty);

        -- payment: сумма = total_amount (BR-8.4), не больше одной успешной (BR-8.1).
        -- Доставляемые/доставленные заказы оплачены; новый - в обработке или с ошибкой;
        -- отменённый - с ошибкой или оплачен (возвратов нет, BR-1.6).
        v_pay_status := case
                            when v_order_status = 'создан'
                            then (array['в_обработке', 'ошибка']::payment_status[])[floor(random() * 2)::int + 1]
                            when v_order_status = 'отменён'
                            then (array['успех', 'ошибка']::payment_status[])[floor(random() * 2)::int + 1]
                            else 'успех'
                        end;

        insert into payment (payment_id, order_id, payment_type, amount, transaction_ref,
                             transaction_timestamp, status)
        values (exts.uuid_generate_v4(),
                v_id,
                (enum_range(null::payment_type))[
                    floor(random() * cardinality(enum_range(null::payment_type)))::int + 1],
                v_total,
                'TXN-' || upper(replace(exts.uuid_generate_v4()::text, '-', '')),       -- BR-8.3
                least(v_order_ts + floor(random() * 11)::int * interval '1 minute', c_now),
                v_pay_status);
    end loop;


    -- 9. review (value * 5). Кандидаты - все допустимые объекты отзыва по заказам
    --    пакета: сам заказ, его ресторан и каждое его блюдо (BR-9.1, BR-9.2).
    --    Каждый кандидат уникален по (order_id, entity_type, entity_id) (BR-9.5).
    --    Кандидатов >= 3 на заказ, т. е. >= value * 15 - хватает всегда.
    --    В приоритете доставленные заказы.
    insert into review (review_id, client_id, review_timestamp, entity_id, entity_type,
                        order_id, description, photo_url, rating)
    select exts.uuid_generate_v4(),
           c.client_id,
           least(date_trunc('second', c.base_ts + random() * interval '3 days'), c_now),
           c.entity_id,
           c.entity_type,
           c.order_id,
           v_review_desc[floor(random() * cardinality(v_review_desc))::int + 1],
           case when random() < 0.5 then null                                       -- BR-9.3
                else 'https://cdn.foodexpress.ru/reviews/' || md5(random()::text) || '.jpg' end,
           floor(random() * 5)::int + 1                                             -- BR-9.4
      from (select o.order_id,
                   o.client_id,
                   o.status,
                   coalesce(o.delivery_timestamp, o.order_timestamp) as base_ts,
                   t.entity_type,
                   e.entity_id
              from "order" o
             cross join unnest(enum_range(null::review_entity_type)) as t(entity_type)
             cross join lateral (
                       select o.order_id      where t.entity_type = 'заказ'
                       union all
                       select o.restaurant_id where t.entity_type = 'ресторан'
                       union all
                       select os.product_id
                         from order_structure os
                        where os.order_id = o.order_id
                          and t.entity_type = 'блюдо'
                   ) as e(entity_id)
             where o.order_id = any (v_orders)
             order by (o.status = 'доставлен') desc, random()
             limit value * 5) c;


    -- 10. Агрегированные рейтинги (BR-9.6) - напрямую, без rating_change.
    --     Отзывы пакета ссылаются только на блюда/рестораны пакета, поэтому
    --     среднее по всем их отзывам = среднее по отзывам пакета. Без отзывов -
    --     NULL (BR-9.7, значение по умолчанию).
    update product p
       set rating = s.avg_rating
      from (select r.entity_id, round(avg(r.rating), 2) as avg_rating
              from review r
             where r.entity_type = 'блюдо'
               and r.entity_id = any (v_products)
             group by r.entity_id) s
     where p.product_id = s.entity_id;

    update restaurant rs
       set rating = s.avg_rating
      from (select r.entity_id, round(avg(r.rating), 2) as avg_rating
              from review r
             where r.entity_type = 'ресторан'
               and r.entity_id = any (v_restaurants)
             group by r.entity_id) s
     where rs.restaurant_id = s.entity_id;


    -- 11. courier_pay за 6 месяцев + courier.coefficient (BR-10.2, BR-10.7).
    --     Помесячно воспроизводим ночной расчёт:
    --       amount           = коэффициент месяца * SUM(commission) доставленных заказов
    --                          курьера, созданных в этом месяце (BR-10.5);
    --       coefficient_used = коэффициент месяца (в первом месяце - 0.1, BR-6.5);
    --       новый коэффициент на следующий месяц - по числу доставок:
    --       0–150 -> 0.1, 151–250 -> 0.2, 251–500 -> 0.3, > 500 -> 0.5 (не больше 0.5).
    --     Уволенному к концу месяца коэффициент больше не меняется (BR-10.6), но
    --     запись за каждый месяц есть (без доставок - 0).
    --     После последнего (текущего) месяца в courier.coefficient - коэффициент
    --     на следующий месяц.
    for i in 1..value loop
        v_coef := 0.1;

        for v_month in
            select g::date
              from generate_series(c_win_start::timestamp,
                                   date_trunc('month', c_now),
                                   interval '1 month') as g
        loop
            select count(*), coalesce(sum(o.commission), 0)
              into v_cnt, v_commission
              from "order" o
             where o.courier_id = v_couriers[i]
               and o.status = 'доставлен'
               and o.order_timestamp >= v_month
               and o.order_timestamp <  v_month + interval '1 month';

            insert into courier_pay (courier_id, year, month, amount, coefficient_used)
            values (v_couriers[i],
                    extract(year  from v_month)::smallint,
                    extract(month from v_month)::smallint,
                    round(v_coef * v_commission, 2),
                    v_coef);

            if v_dismiss[i] is null or v_dismiss[i] >= v_month + interval '1 month' then
                v_coef := case
                              when v_cnt <= 150 then 0.1
                              when v_cnt <= 250 then 0.2
                              when v_cnt <= 500 then 0.3
                              else                   0.5
                          end;
            end if;
        end loop;

        update courier
           set coefficient = v_coef
         where courier_id = v_couriers[i];
    end loop;


    -- 12. BR-6.6: в системе есть хотя бы один активный курьер
    if not exists (select 1 from courier where status <> 'уволен') then
        raise exception 'insert_test_data: нет ни одного активного курьера (BR-6.6)';
    end if;
end;
$$;

comment on procedure insert_test_data(int) is
    'FOOD-102: генерирует тестовый пакет данных по BR-11.7; можно вызывать многократно';
