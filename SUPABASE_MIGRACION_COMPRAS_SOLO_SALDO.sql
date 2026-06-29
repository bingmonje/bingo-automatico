-- Compras de cartones únicamente con saldo de la billetera.
-- Las recargas conservan su comprobante porque son el mecanismo para cargar saldo.

begin;

-- Cierra el flujo antiguo de comprobantes de compra, incluso para clientes viejos.
revoke all on function public.bingo_registrar_comprobante(bigint, text, text)
  from public, anon, authenticated;

-- Evita aprobar manualmente una reserva sin descontar saldo.
revoke all on function public.bingo_admin_aprobar_compra(bigint)
  from public, anon, authenticated;

-- Ya no existe una cola manual de compras que el cliente pueda rechazar.
revoke all on function public.bingo_admin_rechazar_compra(bigint)
  from public, anon, authenticated;

-- Conserva acceso interno para tareas administrativas del servidor.
grant execute on function public.bingo_registrar_comprobante(bigint, text, text) to service_role;
grant execute on function public.bingo_admin_aprobar_compra(bigint) to service_role;
grant execute on function public.bingo_admin_rechazar_compra(bigint) to service_role;

comment on function public.bingo_registrar_comprobante(bigint, text, text)
  is 'Flujo legado deshabilitado: las compras de cartones se pagan solo con saldo.';

notify pgrst, 'reload schema';

commit;
