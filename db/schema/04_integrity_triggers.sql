-- FOOD-101. Триггеры целостности
-- Триггер пересчёта рейтинга rating_change() — отдельный тикет FOOD-105.


set search_path to kuznetsova_food, exts;


-- 1. BR-7.3: позиция заказа — блюдо из ресторана заказа

-- 1a. order_structure: проверка при вставке/изменении позиции и защита
--     отзывов на блюдо от «осиротения» при удалении/изменении позиции (BR-9.2).
create function order_structure_integrity()
returns trigger
language plpgsql
set search_path to kuznetsova_food
as $$
declare
    v_order_restaurant   uuid;
    v_product_restaurant uuid;
begin
    -- позиция удаляется или меняет блюдо/заказ: на неё не должно быть отзыва
    if tg_op = 'DELETE'
       or (tg_op = 'UPDATE' and (new.order_id, new.product_id) is distinct from (old.order_id, old.product_id))
    then
        if exists (select 1
                     from review r
                    where r.order_id    = old.order_id
                      and r.entity_type = 'блюдо'
                      and r.entity_id   = old.product_id)
        then
            raise exception 'Нельзя удалить/изменить позицию заказа %: на блюдо % есть отзыв',
                            old.order_id, old.product_id
                using errcode = 'foreign_key_violation',
                      hint    = 'BR-9.2: отзыв на блюдо возможен только по позиции заказа. Сначала удалите отзыв.';
        end if;
    end if;

    if tg_op = 'DELETE' then
        return old;
    end if;

    select o.restaurant_id into v_order_restaurant
      from "order" o
     where o.order_id = new.order_id;

    select p.restaurant_id into v_product_restaurant
      from product p
     where p.product_id = new.product_id;

    -- отсутствие заказа/блюда — забота FK; здесь только сравнение ресторанов
    if v_order_restaurant is not null
       and v_product_restaurant is not null
       and v_order_restaurant <> v_product_restaurant
    then
        raise exception 'Блюдо % принадлежит ресторану %, а заказ % — ресторану %',
                        new.product_id, v_product_restaurant, new.order_id, v_order_restaurant
            using errcode = 'check_violation',
                  hint    = 'BR-7.3: все блюда в заказе должны быть из ресторана, указанного в заказе.';
    end if;

    return new;
end;
$$;

create trigger order_structure_integrity_trg
    before insert or update or delete on order_structure
    for each row
    execute function order_structure_integrity();


-- 1b. "order": нельзя сменить ресторан у заказа, у которого уже есть позиции
--     (BR-7.3) или отзыв на ресторан (BR-9.2).
create function order_restaurant_guard()
returns trigger
language plpgsql
set search_path to kuznetsova_food
as $$
begin
    if exists (select 1 from order_structure os where os.order_id = new.order_id) then
        raise exception 'Нельзя сменить ресторан заказа %: в заказе уже есть блюда ресторана %',
                        new.order_id, old.restaurant_id
            using errcode = 'check_violation',
                  hint    = 'BR-7.3: все блюда в заказе должны быть из ресторана, указанного в заказе.';
    end if;

    if exists (select 1
                 from review r
                where r.order_id    = new.order_id
                  and r.entity_type = 'ресторан')
    then
        raise exception 'Нельзя сменить ресторан заказа %: на ресторан % по этому заказу есть отзыв',
                        new.order_id, old.restaurant_id
            using errcode = 'check_violation',
                  hint    = 'BR-9.2: клиент может оставить отзыв только на то, что заказал.';
    end if;

    return new;
end;
$$;

create trigger order_restaurant_guard_trg
    before update of restaurant_id on "order"
    for each row
    when (old.restaurant_id is distinct from new.restaurant_id)
    execute function order_restaurant_guard();


-- 1c. product: нельзя «перенести» блюдо в другой ресторан, если оно уже
--     есть в заказах (заказы старого ресторана стали бы некорректными, BR-7.3).
create function product_restaurant_guard()
returns trigger
language plpgsql
set search_path to kuznetsova_food
as $$
begin
    if exists (select 1 from order_structure os where os.product_id = new.product_id) then
        raise exception 'Нельзя сменить ресторан блюда %: блюдо уже есть в заказах ресторана %',
                        new.product_id, old.restaurant_id
            using errcode = 'check_violation',
                  hint    = 'BR-5.1, BR-7.3: блюдо принадлежит одному ресторану; заказы ссылаются на его блюда.';
    end if;

    return new;
end;
$$;

create trigger product_restaurant_guard_trg
    before update of restaurant_id on product
    for each row
    when (old.restaurant_id is distinct from new.restaurant_id)
    execute function product_restaurant_guard();


-- 2. BR-9.1, BR-9.2: полиморфная ссылка review.entity_id
--   'заказ'    — entity_id = order_id            (CHECK review_order_entity_ck)
--   'блюдо'    — блюдо есть в позициях этого заказа
--   'ресторан' — ресторан этого заказа
--   клиент отзыва = клиент заказа               (FK review_order_client_fk)
create function review_entity_check()
returns trigger
language plpgsql
set search_path to kuznetsova_food
as $$
begin
    if new.entity_type = 'блюдо' then
        if not exists (select 1
                         from order_structure os
                        where os.order_id   = new.order_id
                          and os.product_id = new.entity_id)
        then
            raise exception 'Блюда % нет в заказе %', new.entity_id, new.order_id
                using errcode = 'foreign_key_violation',
                      hint    = 'BR-9.2: отзыв на блюдо можно оставить только на блюдо из своего заказа.';
        end if;

    elsif new.entity_type = 'ресторан' then
        if not exists (select 1
                         from "order" o
                        where o.order_id      = new.order_id
                          and o.restaurant_id = new.entity_id)
        then
            raise exception 'Ресторан % не является рестораном заказа %', new.entity_id, new.order_id
                using errcode = 'foreign_key_violation',
                      hint    = 'BR-9.2: отзыв на ресторан можно оставить только на ресторан своего заказа.';
        end if;
    end if;
    -- 'заказ' проверяется CHECK review_order_entity_ck

    return new;
end;
$$;

create trigger review_entity_check_trg
    before insert or update of entity_type, entity_id, order_id on review
    for each row
    execute function review_entity_check();


-- 3. BR-8.7: агрегированный статус оплаты заказа
--   'оплачен' — есть успешная попытка;
--   'ошибка'  — попытки есть, и все завершились ошибкой;
--   'ожидает' — иначе (есть попытки в обработке или попыток ещё нет).

create function calc_order_pay_status(p_order_id uuid)
returns order_pay_status
language sql
stable
set search_path to kuznetsova_food
as $$
    select case
               when bool_or(p.status = 'успех')                       then 'оплачен'
               when count(*) > 0 and bool_and(p.status = 'ошибка')     then 'ошибка'
               else                                                         'ожидает'
           end::order_pay_status
      from payment p
     where p.order_id = p_order_id;
$$;

-- 3a. pay_status нельзя выставить вручную в значение, не соответствующее
--     попыткам оплаты: при вставке заказа и при изменении pay_status
--     значение всегда вычисляется заново.
create function order_pay_status_enforce()
returns trigger
language plpgsql
set search_path to kuznetsova_food
as $$
begin
    new.pay_status := calc_order_pay_status(new.order_id);
    return new;
end;
$$;

create trigger order_pay_status_enforce_trg
    before insert or update of pay_status on "order"
    for each row
    execute function order_pay_status_enforce();

-- 3b. Любое изменение попыток оплаты пересчитывает статус заказа.
create function payment_sync_order_pay_status()
returns trigger
language plpgsql
set search_path to kuznetsova_food
as $$
begin
    -- заказ, к которому попытка относилась до изменения
    if tg_op in ('UPDATE', 'DELETE') then
        update "order" o
           set pay_status = calc_order_pay_status(o.order_id)
         where o.order_id = old.order_id;
    end if;

    -- заказ, к которому попытка относится после изменения (если это другой заказ)
    if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.order_id <> old.order_id) then
        update "order" o
           set pay_status = calc_order_pay_status(o.order_id)
         where o.order_id = new.order_id;
    end if;

    return null;
end;
$$;

create trigger payment_sync_order_pay_status_trg
    after insert or update of order_id, status or delete on payment
    for each row
    execute function payment_sync_order_pay_status();
