# bingo-automatico

Bingo automático optimizado para un máximo operativo de 80 cartones/jugadores por partida.

## Activar ahorro de Realtime

Ejecuta una sola vez en **Supabase > SQL Editor** el archivo:

- `SUPABASE_FIX_MOVIMIENTOS_CLIENTE.sql`

El archivo ahora incluye:

- corrección de la lista de movimientos;
- compra con consulta ligera cada 5 segundos;
- una sola señal Realtime por bola;
- eventos compactos de inicio, premios y final;
- máximo de 80 cartones;
- un cupo de sala por cuenta;
- liberación automática de conexiones al finalizar.

Después de ejecutar el SQL, actualiza la página con `Ctrl + F5`.
