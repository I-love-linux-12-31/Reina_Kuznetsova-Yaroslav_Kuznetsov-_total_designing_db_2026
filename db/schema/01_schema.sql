-- FOOD-101. Схема kuznetsova_food

drop schema if exists kuznetsova_food cascade;

create schema kuznetsova_food;

comment on schema kuznetsova_food is 'FoodExpress: база данных сервиса доставки еды';

set search_path to kuznetsova_food, exts;
