# Prueba progresiva de capacidad

Esta prueba solo consulta `bingo_resumen_sala` y abre una conexion Realtime
por jugador simulado. No registra usuarios, no compra cartones y no modifica
saldos ni partidas.

## Orden recomendado para Supabase Free

1. 25 usuarios durante 2 minutos.
2. 50 usuarios durante 2 minutos.
3. 100 usuarios durante 5 minutos.
4. 150 usuarios durante 5 minutos.
5. 180 usuarios durante 10 minutos.

No ejecutar el siguiente nivel si falla alguno de estos limites:

- menos de 1 % de peticiones HTTP fallidas;
- respuesta p95 menor de 1 segundo;
- mas de 99 % de conexiones y uniones Realtime correctas;
- menos de 2 errores Realtime.

Ejecutar solamente cuando no haya una partida real en curso. El plan Free
admite 200 conexiones Realtime simultaneas, por eso el flujo no permite
superar 180 y deja margen para el administrador y las conexiones normales.
