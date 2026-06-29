# Estado de Supabase después de la optimización

Fecha de auditoría: 2026-06-29, zona horaria America/Caracas.

## Aplicado

- Migración principal V2 con RPC, índices y validación de ganadores.
- Restricción de ejecución de helpers internos.
- Corrección de la clave real `cantidad_cartones_disponibles`.
- Índices para claves foráneas pendientes.
- Consolidación de policies RLS redundantes.
- Ampliación de `cantidad_cartones_disponibles` de 100 a 1.000.
- Cierre transaccional de ventas durante partidas activas y revocación de
  escrituras directas del rol anónimo sobre ventas, saldos y bolas.
- Sorteo automático del lado del servidor mediante `pg_cron`, cada 5 segundos.
- Programación repetitiva de partidas, cuenta regresiva pública y cierre
  automático de ventas al comenzar cada juego.
- Validación y pago de premios desde el servidor para que el ciclo no dependa
  de mantener abierta la pestaña del administrador o del ganador.
- Limpieza diaria del historial técnico de Cron con retención de 7 días.
- Mínimo obligatorio de 15 cartones aprobados antes de iniciar manual o
  automáticamente; si faltan cartones, la cuenta se repite cada minuto.
- Estado público de programación con total vendido, mínimo y cartones faltantes.
- Compras de cartones exclusivamente con saldo: se deshabilitaron para los
  clientes el comprobante de compra y la aprobación o rechazo manual que podía
  evitar el descuento de la billetera.

## Conservado intencionalmente

- Los datos existentes.
- Dos pares de bolas duplicadas pertenecientes a juegos históricos.
- Las policies permisivas necesarias para que el frontend actual siga
  funcionando sin Supabase Auth.

## Resultado de asesores

- Rendimiento: 0 errores, 0 advertencias.
- Seguridad: 7 errores y 60 advertencias preexistentes o derivadas del modelo
  de acceso anónimo actual.

Las advertencias principales son RLS desactivado en tablas públicas, policies
demasiado permisivas, funciones `SECURITY DEFINER` expuestas y listado público
del bucket de comprobantes.

Referencia: https://supabase.com/docs/guides/database/database-linter
