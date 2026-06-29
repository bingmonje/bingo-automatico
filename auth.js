function obtenerUsuarioSesion() {
  try {
    return JSON.parse(localStorage.getItem('usuario_bingo'));
  } catch {
    return null;
  }
}

function cerrarSesion() {
  localStorage.removeItem('usuario_bingo');
  window.location.href = 'login.html';
}

function requerirSesion() {
  const usuario = obtenerUsuarioSesion();
  if (!usuario) {
    window.location.href = 'login.html';
    return null;
  }
  return usuario;
}
