create table songs(
    id bigserial primary key,
    title text not null,
    artist text not null,
);

create table queue(
    id bigserial primary key,
    submitted timestamp with time zone default now(),
    nickname text not null,
    song bigint not null references songs(id),
    visible boolean not null default true
);
