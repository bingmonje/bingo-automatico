import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

type PushPayload = {
  target: 'admin' | 'cliente';
  usuario_id?: number;
  title?: string;
  body?: string;
  url?: string;
  tag?: string;
};

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const webhookSecret = Deno.env.get('BINGO_PUSH_WEBHOOK_SECRET') ?? '';
const vapidPublicKey = Deno.env.get('BINGO_VAPID_PUBLIC_KEY') ?? '';
const vapidPrivateKey = Deno.env.get('BINGO_VAPID_PRIVATE_KEY') ?? '';
const vapidSubject = Deno.env.get('BINGO_VAPID_SUBJECT') ?? 'mailto:goldenpro.ven@gmail.com';

if (vapidPublicKey && vapidPrivateKey) {
  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }
  if (!webhookSecret || request.headers.get('x-bingo-push-secret') !== webhookSecret) {
    return new Response('Unauthorized', { status: 401 });
  }
  if (!supabaseUrl || !serviceRoleKey || !vapidPublicKey || !vapidPrivateKey) {
    return Response.json({ ok: false, error: 'push_not_configured' }, { status: 503 });
  }

  let payload: PushPayload;
  try {
    payload = await request.json();
  } catch {
    return Response.json({ ok: false, error: 'invalid_json' }, { status: 400 });
  }

  if (payload.target !== 'admin' && payload.target !== 'cliente') {
    return Response.json({ ok: false, error: 'invalid_target' }, { status: 400 });
  }
  if (payload.target === 'cliente' && !Number.isFinite(Number(payload.usuario_id))) {
    return Response.json({ ok: false, error: 'invalid_user' }, { status: 400 });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false }
  });
  let consulta = supabase
    .from('push_suscripciones')
    .select('id,endpoint,p256dh,auth')
    .eq('activo', true);
  consulta = payload.target === 'admin'
    ? consulta.eq('recibe_admin', true)
    : consulta.eq('usuario_id', Number(payload.usuario_id));

  const { data: suscripciones, error } = await consulta;
  if (error) {
    console.error('Error consultando suscripciones:', error);
    return Response.json({ ok: false, error: 'subscription_query_failed' }, { status: 500 });
  }

  const mensaje = JSON.stringify({
    title: String(payload.title || 'Bingo Express GP').slice(0, 100),
    body: String(payload.body || 'Tienes una nueva notificación.').slice(0, 280),
    url: String(payload.url || 'cuenta.html').slice(0, 200),
    tag: String(payload.tag || 'bingo-express-gp').slice(0, 120)
  });

  let enviados = 0;
  const vencidas: number[] = [];
  await Promise.all((suscripciones || []).map(async (suscripcion) => {
    try {
      await webpush.sendNotification({
        endpoint: suscripcion.endpoint,
        keys: { p256dh: suscripcion.p256dh, auth: suscripcion.auth }
      }, mensaje, { TTL: 300, urgency: 'high' });
      enviados += 1;
    } catch (pushError) {
      const statusCode = Number((pushError as { statusCode?: number })?.statusCode || 0);
      if (statusCode === 404 || statusCode === 410) {
        vencidas.push(Number(suscripcion.id));
      } else {
        console.error('Error enviando Push:', statusCode, pushError);
      }
    }
  }));

  if (vencidas.length) {
    const { error: limpiarError } = await supabase
      .from('push_suscripciones')
      .update({ activo: false, actualizado_en: new Date().toISOString() })
      .in('id', vencidas);
    if (limpiarError) console.error('Error desactivando suscripciones vencidas:', limpiarError);
  }

  return Response.json({
    ok: true,
    encontrados: suscripciones?.length || 0,
    enviados,
    vencidos: vencidas.length
  });
});
