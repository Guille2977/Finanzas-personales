/**
 * logica_test.ts — las mismas pruebas que Pruebas.gs, para la lógica del bot.
 * Ejecutar:  deno run logica_test.ts   (o  node --experimental-strip-types logica_test.ts)
 */
import {
  anonimizar, dataBoton, detectarSentido, interpretarMensaje, lunesLima, normalizar, palabraClave,
  pareceMonto, textoParaClasificar, validarInterpretacion, validarSugerencia,
} from "./logica.ts";

function resumenItem(texto: string, n = 0) {
  const it = interpretarMensaje(texto)[n];
  return [it.monto, it.sentido, it.medio, it.diasAtras, it.contraparte, it.concepto];
}

const CATS_PRUEBA = [
  { id_categoria: 1, nombre: 'Transporte', tipo: 'egreso' },
  { id_categoria: 2, nombre: 'Comida', tipo: 'egreso' },
  { id_categoria: 7, nombre: 'Pagos recibidos', tipo: 'ingreso' },
];

const casos: [string, () => unknown, unknown][] = [
    ['sin monto: no se llama a la IA', () => pareceMonto('Brownnie'), false],
    ['monto en palabras: sí', () => pareceMonto('galletas por cuatro cincuenta'), true],
    ['normalizar Menú Ñandú', () => normalizar('  Menú  ÑANDÚ!'), 'menu ñandu'],
    ['lunes de la semana (miércoles 18/11/2026)', () => lunesLima(new Date('2026-11-18T15:00:00Z')), '2026-11-16'],
    ['lunes cuando ya es lunes', () => lunesLima(new Date('2026-11-16T15:00:00Z')), '2026-11-16'],
    ['domingo 22/11 → lunes 16/11', () => lunesLima(new Date('2026-11-22T15:00:00Z')), '2026-11-16'],

    // Tabla de la sección 8 del documento: [monto, sentido, medio, díasAtrás, contraparte, concepto]
    ['bot: pasaje 3', () => resumenItem('pasaje 3'), [3, 'egreso', 'efectivo', 0, null, 'pasaje']],
    ['bot: queque .2', () => resumenItem('queque .2'), [0.2, 'egreso', 'efectivo', 0, null, 'queque']],
    ['bot: desayuno 5.50', () => resumenItem('desayuno 5.50'), [5.5, 'egreso', 'efectivo', 0, null, 'desayuno']],
    ['bot: 3 soles de pasaje', () => resumenItem('3 soles de pasaje'), [3, 'egreso', 'efectivo', 0, null, 'pasaje']],
    ['bot: S/ 3,50 menú', () => resumenItem('S/ 3,50 menú'), [3.5, 'egreso', 'efectivo', 0, null, 'menu']],
    ['bot: s/.4 pan', () => resumenItem('s/.4 pan'), [4, 'egreso', 'efectivo', 0, null, 'pan']],
    ['bot: 25 menú efectivo', () => resumenItem('25 menú efectivo'), [25, 'egreso', 'efectivo', 0, null, 'menu']],
    ['bot: yape 10 almuerzo', () => resumenItem('yape 10 almuerzo'), [10, 'egreso', 'yape', 0, null, 'almuerzo']],
    ['bot: yape 10 a Pedro por la cuota', () => resumenItem('yape 10 a Pedro por la cuota'),
      [10, 'egreso', 'yape', 0, 'Pedro', 'cuota']],
    ['bot: ayer menú 12', () => resumenItem('ayer menú 12'), [12, 'egreso', 'efectivo', 1, null, 'menu']],
    ['bot: dos gastos', () => interpretarMensaje('pasaje 3, golosina 1.5').map(i => [i.monto, i.concepto]),
      [[3, 'pasaje'], [1.5, 'golosina']]],
    ['bot: la fecha se hereda', () => interpretarMensaje('ayer menú 12; pasaje 3').map(i => i.diasAtras), [1, 1]],
    ['bot: me pagaron 50', () => resumenItem('me pagaron 50'), [50, 'ingreso', 'efectivo', 0, null, '']],
    ['bot: me yapearon 5 de Ana', () => resumenItem('me yapearon 5 de Ana'), [5, 'ingreso', 'yape', 0, 'Ana', '']],
    // Sentido (ingreso/egreso): bug del 20/11, "me han yapeado 1 sol" se registró como gasto.
    ['sentido: me han yapeado 1 sol → ingreso Yape', () => resumenItem('me han yapeado 1 sol'),
      [1, 'ingreso', 'yape', 0, null, '']],
    ['sentido: ME HAN YAPEADO (mayúsculas) → ingreso', () => resumenItem('ME HAN YAPEADO 1 SOL')[1], 'ingreso'],
    ['sentido: me depositaron 100 → ingreso efectivo', () => resumenItem('me depositaron 100')[1], 'ingreso'],
    ['sentido: recibí 20 de propina (tilde) → ingreso', () => resumenItem('recibí 20 de propina'),
      [20, 'ingreso', 'efectivo', 0, null, 'propina']],
    ['sentido: le yapeé 5 a Ana → sigue siendo gasto', () => resumenItem('yapee 5 a Ana')[1], 'egreso'],
    ['sentido: palabra suelta no basta ("gane" ≠ "ganesha")', () => detectarSentido(['ganesha', 'polo']).sentido, 'egreso'],
    ['sentido: la frase más larga gana', () => detectarSentido(['me', 'devolvieron'],
      [{ frase: 'devolvieron', sentido: 'egreso' }, { frase: 'me devolvieron', sentido: 'ingreso' }]).sentido, 'ingreso'],
    ['sentido: frases desde la tabla (configuración)', () => interpretarMensaje('me cayo 30 del freelance',
      [{ frase: 'me cayo', sentido: 'ingreso' }])[0].sentido, 'ingreso'],
    ['sentido: frase de la tabla sin normalizar ("Me cayó")', () => detectarSentido(['me', 'cayo', 'plata'],
      [{ frase: 'Me cayó', sentido: 'ingreso' }]).frase, 'me cayo'],
    ['bot: sin monto', () => resumenItem('hola'), [null, 'egreso', 'efectivo', 0, null, 'hola']],
    ['bot: dos números → ambiguo', () => interpretarMensaje('pasaje 3 y 4')[0].ambiguo, true],
    ['bot: el marcado gana', () => resumenItem('menú 2 platos 15 soles')[0], 15],
    ['bot: frase libre', () => resumenItem('me compré unas galletas y una gaseosa por 4.50'),
      [4.5, 'egreso', 'efectivo', 0, null, 'galletas gaseosa']],
    // La regla de clasificación se prueba en sql/09_fn_clasificar.sql (es la misma de los correos).
    ['bot: texto a clasificar = contraparte + concepto', () =>
      textoParaClasificar(interpretarMensaje('yape 10 a Pedro cuota polla')[0]), 'Pedro cuota polla'],
    ['bot: palabra clave', () => palabraClave('galletas gaseosa'), 'galletas'],
    ['bot: botón ≤ 64 bytes', () => {
      const d = dataBoton(['k', 123456789, 12], 'ñ'.repeat(60));
      return new TextEncoder().encode(d).length <= 64;
    }, true],
    ['bot: botón sin palabra', () => dataBoton(['k', 5, 2], ''), 'k|5|2|'],
    // IA: validación de la respuesta (la IA puede equivocarse; aquí se filtra)
    ['ia: sugerencia válida', () => validarSugerencia({ categoria: 'Comida', palabra_clave: 'Galletas' },
      'galletas gaseosa', CATS_PRUEBA), { id_categoria: 2, nombre: 'Comida', icono: null, palabra: 'galletas' }],
    ['ia: categoría inventada → null', () => validarSugerencia({ categoria: 'Snacks', palabra_clave: 'x' },
      'galletas', CATS_PRUEBA), null],
    ['ia: palabra que no está en el texto → no se aprende', () => validarSugerencia(
      { categoria: 'Comida', palabra_clave: 'comida' }, 'galletas', CATS_PRUEBA).palabra, ''],
    ['ia: interpretación válida', () => validarInterpretacion({ entendido: true, monto: 4.5, sentido: 'egreso',
      medio: 'efectivo', categoria: 'Comida', dias_atras: 0, palabra_clave: 'galletas' },
      'galletas por cuatro cincuenta', CATS_PRUEBA, 10000, 7),
      { monto: 4.5, sentido: 'egreso', medio: 'efectivo', dias: 0, id_categoria: 2, palabra: 'galletas' }],
    ['ia: monto 0 → null', () => validarInterpretacion({ entendido: true, monto: 0, sentido: 'egreso',
      medio: 'efectivo', categoria: 'Comida', dias_atras: 0 }, 'x', CATS_PRUEBA, 10000, 7), null],
    ['ia: 30 días atrás → null', () => validarInterpretacion({ entendido: true, monto: 5, sentido: 'egreso',
      medio: 'efectivo', categoria: 'Comida', dias_atras: 30 }, 'x', CATS_PRUEBA, 10000, 7), null],
    ['ia: categoría de otro tipo → sin categoría', () => validarInterpretacion({ entendido: true, monto: 5,
      sentido: 'ingreso', medio: 'yape', categoria: 'Comida', dias_atras: 0 }, 'x', CATS_PRUEBA, 10000, 7).id_categoria, null],
    ['ia: anonimiza celular y correo', () => anonimizar('yape 10 a 987 654 321 o yo@mail.com'),
      'yape 10 a [número] o [correo]'],
  ];

let fallos = 0;
for (const [nombre, fn, esperado] of casos) {
  let obtenido: unknown;
  try { obtenido = fn(); } catch (e) { obtenido = 'ERROR: ' + (e as Error).message; }
  const ok = JSON.stringify(obtenido) === JSON.stringify(esperado);
  if (!ok) fallos++;
  console.log(`${ok ? '✅' : '❌'} ${nombre}${ok ? '' : ` → esperado ${JSON.stringify(esperado)}, obtenido ${JSON.stringify(obtenido)}`}`);
}
console.log(`${casos.length - fallos}/${casos.length} pruebas OK`);
if (fallos) throw new Error(`${fallos} prueba(s) fallaron`);
