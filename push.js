(function () {
  'use strict';

  const VAPID_PUBLIC_KEY = 'BPkVtPxety6ChNNqjgMfDf9WeaPwcRKATPyoKOkmtX9o9_4VgzxPP_IE67ahk81cWjGHVrw2ok7-RCBaCwBTX8Q';

  function soportado() {
    return 'serviceWorker' in navigator
      && 'PushManager' in window
      && 'Notification' in window;
  }

  function base64AUint8Array(valor) {
    const relleno = '='.repeat((4 - (valor.length % 4)) % 4);
    const base64 = (valor + relleno).replace(/-/g, '+').replace(/_/g, '/');
    const binario = atob(base64);
    return Uint8Array.from([...binario].map(caracter => caracter.charCodeAt(0)));
  }

  async function obtenerRegistro() {
    await navigator.serviceWorker.register('./push-sw.js', { scope: './' });
    return navigator.serviceWorker.ready;
  }

  async function obtenerSuscripcion() {
    if (!soportado()) return null;
    const registro = await obtenerRegistro();
    return registro.pushManager.getSubscription();
  }

  function pintarBoton(boton, estado, texto) {
    if (!boton) return;
    boton.dataset.pushEstado = estado;
    boton.disabled = estado === 'procesando';
    boton.textContent = texto;
    boton.classList.toggle('push-activo', estado === 'activo');
    boton.classList.toggle('push-error', estado === 'error');
  }

  function mensajeNoCompatible() {
    const esIOS = /iphone|ipad|ipod/i.test(navigator.userAgent);
    if (esIOS && !window.matchMedia('(display-mode: standalone)').matches) {
      return 'En iPhone, primero abre el menú Compartir y elige “Agregar a pantalla de inicio”. Luego entra desde ese icono y activa las notificaciones.';
    }
    return 'Este navegador no permite notificaciones Push. Usa Chrome, Edge o instala la página en la pantalla de inicio.';
  }

  async function solicitarSuscripcion() {
    if (!soportado()) throw new Error(mensajeNoCompatible());

    let permiso = Notification.permission;
    if (permiso === 'default') permiso = await Notification.requestPermission();
    if (permiso !== 'granted') {
      throw new Error('Las notificaciones están bloqueadas. Habilítalas en la configuración del navegador.');
    }

    const registro = await obtenerRegistro();
    let suscripcion = await registro.pushManager.getSubscription();
    if (!suscripcion) {
      suscripcion = await registro.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: base64AUint8Array(VAPID_PUBLIC_KEY)
      });
    }
    return suscripcion;
  }

  async function guardar(supabaseClient, funcion, token, suscripcion) {
    const json = suscripcion.toJSON();
    const { data, error } = await supabaseClient.rpc(funcion, {
      p_token: token,
      p_endpoint: suscripcion.endpoint,
      p_p256dh: json.keys?.p256dh || '',
      p_auth: json.keys?.auth || '',
      p_user_agent: navigator.userAgent
    });

    if (error || !data?.ok) {
      throw new Error(error?.message || data?.codigo || 'No se pudo guardar la suscripción.');
    }
  }

  async function activar({ supabaseClient, token, tipo, boton }) {
    if (!token) throw new Error('La sesión venció. Inicia sesión nuevamente.');
    pintarBoton(boton, 'procesando', '⏳ Activando notificaciones...');

    try {
      const suscripcion = await solicitarSuscripcion();
      const funcion = tipo === 'admin'
        ? 'bingo_push_suscribir_admin'
        : 'bingo_push_suscribir_cliente';
      await guardar(supabaseClient, funcion, token, suscripcion);
      pintarBoton(boton, 'activo', '🔔 Notificaciones activadas');

      const registro = await navigator.serviceWorker.ready;
      await registro.showNotification('Bingo Express GP', {
        body: 'Notificaciones activadas correctamente.',
        icon: './icon.svg',
        badge: './icon.svg',
        tag: `bingo-push-activado-${tipo}`,
        silent: false
      });
      return true;
    } catch (error) {
      pintarBoton(boton, 'error', '🔕 Activar notificaciones');
      alert(error.message || 'No se pudieron activar las notificaciones.');
      return false;
    }
  }

  async function sincronizar({ supabaseClient, token, tipo, boton }) {
    if (!soportado()) {
      pintarBoton(boton, 'error', '🔕 Activar notificaciones');
      return false;
    }

    try {
      const suscripcion = await obtenerSuscripcion();
      if (!suscripcion || Notification.permission !== 'granted') {
        pintarBoton(boton, 'inactivo', '🔕 Activar notificaciones');
        return false;
      }

      const funcion = tipo === 'admin'
        ? 'bingo_push_suscribir_admin'
        : 'bingo_push_suscribir_cliente';
      await guardar(supabaseClient, funcion, token, suscripcion);
      pintarBoton(boton, 'activo', '🔔 Notificaciones activadas');
      return true;
    } catch (error) {
      console.warn('No se pudo sincronizar Push:', error);
      pintarBoton(boton, 'inactivo', '🔕 Activar notificaciones');
      return false;
    }
  }

  window.BingoPush = { activar, sincronizar, soportado, obtenerSuscripcion };
})();
