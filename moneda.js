(() => {
  const formatoMonto = new Intl.NumberFormat('es-VE', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });

  const formatoEntero = new Intl.NumberFormat('es-VE', {
    maximumFractionDigits: 0
  });

  function parsear(valor) {
    if (typeof valor === 'number') return Number.isFinite(valor) ? valor : 0;

    let texto = String(valor ?? '').trim().replace(/\s/g, '');
    if (!texto) return 0;

    if (texto.includes(',')) {
      texto = texto.replace(/\./g, '').replace(',', '.');
    } else if (/^\d{1,3}(\.\d{3})+$/.test(texto)) {
      texto = texto.replace(/\./g, '');
    }

    texto = texto.replace(/[^0-9.-]/g, '');
    const numero = Number(texto);
    return Number.isFinite(numero) ? numero : 0;
  }

  function formatear(valor) {
    return formatoMonto.format(parsear(valor));
  }

  function conBs(valor) {
    return `${formatear(valor)} Bs`;
  }

  function duranteEscritura(input) {
    let texto = String(input.value || '').replace(/\s/g, '').replace(/\./g, '');
    texto = texto.replace(/[^0-9,]/g, '');

    if (!texto) {
      input.value = '';
      return;
    }

    const tieneComa = texto.includes(',');
    const partes = texto.split(',');
    let entero = (partes.shift() || '').replace(/^0+(?=\d)/, '');
    const decimales = partes.join('').slice(0, 2);
    if (!entero) entero = '0';

    input.value = formatoEntero.format(Number(entero || 0));
    if (tieneComa) input.value += `,${decimales}`;
  }

  function finalizarEntrada(input) {
    if (!String(input.value || '').trim()) return;
    input.value = formatear(input.value);
  }

  function configurarInput(input) {
    if (!input || input.dataset.monedaVe === '1') return;
    input.dataset.monedaVe = '1';
    input.setAttribute('inputmode', 'decimal');
    input.setAttribute('autocomplete', 'off');
    input.addEventListener('input', () => duranteEscritura(input));
    input.addEventListener('blur', () => finalizarEntrada(input));
  }

  window.BingoMoneda = {
    parsear,
    formatear,
    conBs,
    configurarInput
  };
})();
