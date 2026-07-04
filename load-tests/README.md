# Prueba progresiva de capacidad

Esta prueba solo consulta `bingo_resumen_sala` y abre una conexion Realtime
por jugador simulado. Cada jugador conserva la misma conexion durante toda la
duracion elegida. No registra usuarios, no compra cartones y no modifica saldos
ni partidas.

## Orden recomendado para Supabase Free

1. 25 usuarios durante 2 minutos.
2. 50 usuarios durante 2 minutos.
3. 80 usuarios durante 10 minutos.
4. 90 usuarios durante 10 minutos.
5. 100 usuarios durante 2 minutos como prueba de margen.

No ejecutar el siguiente nivel si falla alguno de estos limites:

- menos de 1 % de peticiones HTTP fallidas;
- respuesta p95 menor de 1 segundo;
- mas de 99 % de conexiones y uniones Realtime correctas;
- menos de 2 errores Realtime.

Ejecutar solamente cuando no haya una partida real en curso. El limite
operativo recomendado es 90 para dejar margen para el administrador, las
reconexiones reales y otras conexiones normales.
