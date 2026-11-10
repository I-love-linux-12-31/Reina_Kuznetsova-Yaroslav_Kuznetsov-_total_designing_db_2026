-- FOOD-103. Удаление тестовых данных erase_test_data()
--
-- Удаляет все строки из всех таблиц схемы. Порядок — от дочерних таблиц
-- к родительским, чтобы ни один FK не был нарушен. DELETE (а не TRUNCATE):
-- достаточно прав на DELETE, срабатывают триггеры целостности.


set search_path to kuznetsova_food, exts;


create or replace procedure erase_test_data()
language plpgsql
set search_path to kuznetsova_food
as $$
begin
    delete from review;            -- "order", client (+ ссылки на блюдо/ресторан)
    delete from payment;           -- "order"
    delete from order_structure;   -- "order", product
    delete from "order";           -- courier, client, client_address, address, restaurant
    delete from courier_pay;       -- courier
    delete from client_address;    -- client, address
    delete from client;
    delete from product;           -- restaurant, product_category
    delete from product_category;
    delete from restaurant;        -- address
    delete from courier;
    delete from address;
end;
$$;

comment on procedure erase_test_data() is
    'FOOD-103: удаляет все данные из всех таблиц схемы с учётом FK';
