import http from 'k6/http';
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const SUPABASE_URL = 'https://okwkwgrecwxydjcezcdn.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rd2t3Z3JlY3d4eWRqY2V6Y2RuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA1NzQzNzcsImV4cCI6MjA4NjE1MDM3N30.r-xcTbAoHiy5_qrk9JWQMCqjXERDZKjuecqzLGMBHuQ';
const VUS = Math.min(180, Math.max(1, Number(__ENV.VUS || 25)));
const DURATION = __ENV.DURATION || '2m';
function durationToMs(value) {
  const match = String(value).trim().match(/^(\d+(?:\.\d+)?)(ms|s|m|h)$/);
  if (!match) return 120000;

  const multipliers = { ms: 1, s: 1000, m: 60000, h: 3600000 };
  return Number(match[1]) * multipliers[match[2]];
}

// Cada VU conserva una sola conexion durante toda la prueba. Se cierra cinco
// segundos antes del maxDuration para que k6 pueda registrar el resultado.
const HOLD_MS = Math.max(30000, durationToMs(DURATION) - 5000);

const realtimeConnected = new Rate('realtime_connected');
const realtimeJoined = new Rate('realtime_joined');
const realtimeErrors = new Counter('realtime_errors');
const realtimeMessages = new Counter('realtime_messages');
const realtimeJoinMs = new Trend('realtime_join_ms', true);

export const options = {
  scenarios: {
    jugadores_sala: {
      executor: 'per-vu-iterations',
      vus: VUS,
      iterations: 1,
      maxDuration: DURATION,
      exec: 'jugadorSala',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
    realtime_connected: ['rate>0.99'],
    realtime_joined: ['rate>0.99'],
    realtime_errors: ['count<2'],
  },
};

const restHeaders = {
  headers: {
    apikey: SUPABASE_KEY,
    Authorization: `Bearer ${SUPABASE_KEY}`,
    'Content-Type': 'application/json',
  },
  tags: { endpoint: 'bingo_resumen_sala' },
};

export function jugadorSala() {
  const resumen = http.post(
    `${SUPABASE_URL}/rest/v1/rpc/bingo_resumen_sala`,
    '{}',
    restHeaders,
  );

  check(resumen, {
    'resumen responde 200': (r) => r.status === 200,
    'resumen devuelve JSON': (r) => {
      try {
        return typeof r.json() === 'object';
      } catch (_) {
        return false;
      }
    },
  });

  const wsUrl = `${SUPABASE_URL.replace('https://', 'wss://')}/realtime/v1/websocket?apikey=${encodeURIComponent(SUPABASE_KEY)}&vsn=1.0.0`;
  const topic = `realtime:carga-sala-${__VU}-${__ITER}`;
  const inicio = Date.now();
  let unido = false;
  let ref = 1;

  const respuesta = ws.connect(wsUrl, { tags: { endpoint: 'supabase_realtime' } }, (socket) => {
    socket.on('open', () => {
      socket.send(JSON.stringify({
        topic,
        event: 'phx_join',
        payload: {
          config: {
            broadcast: { ack: false, self: false },
            presence: { key: '' },
            postgres_changes: [
              { event: '*', schema: 'public', table: 'bingo_automatico' },
              { event: 'INSERT', schema: 'public', table: 'bolas_auto' },
              { event: '*', schema: 'public', table: 'cartones_vendidos' },
            ],
            private: false,
          },
          access_token: SUPABASE_KEY,
        },
        ref: String(ref),
        join_ref: String(ref),
      }));
    });

    socket.on('message', (mensaje) => {
      realtimeMessages.add(1);
      try {
        const evento = JSON.parse(mensaje);
        if (!unido && evento.event === 'phx_reply' && evento.payload?.status === 'ok') {
          unido = true;
          realtimeJoined.add(true);
          realtimeJoinMs.add(Date.now() - inicio);
        }
        if (evento.event === 'phx_error' || evento.payload?.status === 'error') {
          realtimeErrors.add(1);
        }
      } catch (_) {
        realtimeErrors.add(1);
      }
    });

    socket.on('error', () => realtimeErrors.add(1));

    socket.setInterval(() => {
      ref += 1;
      socket.send(JSON.stringify({
        topic: 'phoenix', event: 'heartbeat', payload: {}, ref: String(ref), join_ref: null,
      }));
    }, 25000);

    socket.setTimeout(() => socket.close(), HOLD_MS);
  });

  const conectado = check(respuesta, {
    'websocket responde 101': (r) => r && r.status === 101,
  });
  realtimeConnected.add(conectado);
  if (!unido) realtimeJoined.add(false);
  sleep(1);
}

