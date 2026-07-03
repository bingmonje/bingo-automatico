-- Corrige el tipo bigint de usuarios_bingo.id en las listas seguras del admin.
-- Puede ejecutarse varias veces sin duplicar datos.

begin;

create or replace function public.bingo_admin_listar_clientes_seguro(p_token text)
returns table (id integer, nombre text, cedula text, telefono text, saldo numeric)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return query
    select u.id::integer, u.nombre::text, u.cedula::text, u.telefono::text,
           coalesce(b.saldo, 0)
      from public.usuarios_bingo u
      left join public.billeteras_bingo b on b.usuario_id = u.id
     order by u.id;
end;
$$;

create or replace function public.bingo_admin_listar_recuperaciones_seguro(p_token text)
returns table (
  id bigint, usuario_id integer, nombre text, cedula text,
  telefono text, solicitado_en timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return query
    select r.id, u.id::integer, u.nombre::text, u.cedula::text,
           u.telefono::text, r.solicitado_en
      from public.recuperaciones_pin_bingo r
      join public.usuarios_bingo u on u.id = r.usuario_id
     where r.estado = 'pendiente'
     order by r.solicitado_en asc;
end;
$$;

revoke all on function public.bingo_admin_listar_clientes_seguro(text)
  from public, anon, authenticated;
revoke all on function public.bingo_admin_listar_recuperaciones_seguro(text)
  from public, anon, authenticated;

grant execute on function public.bingo_admin_listar_clientes_seguro(text)
  to anon, authenticated;
grant execute on function public.bingo_admin_listar_recuperaciones_seguro(text)
  to anon, authenticated;

notify pgrst, 'reload schema';

commit;
