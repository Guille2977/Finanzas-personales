# Bot en Apps Script (archivado el 16/11/2026)

Primera versión del bot. Funcionaba, pero se reemplazó por la Edge Function
`supabase/functions/telegram-webhook` por dos motivos medidos:

1. Apps Script responde al webhook con un **302**; Telegram lo toma como fallo,
   reintenta el mismo mensaje y frena los siguientes.
2. Aun con un receptor intermedio, cada mensaje tardaba **2–3 s** (arranque de
   Apps Script + 4–6 llamadas por internet). En la Edge Function, junto a la base, < 1 s.

Se conserva como referencia (historial de decisiones). No pegar en el proyecto de Apps Script.
