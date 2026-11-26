# Configurações de P&R (LibreLane)

Uma pasta por bloco, cada uma com um `config.json` para
`make pnr PNR_CONFIG=pnr/<bloco>/config.json`. O LibreLane cria `runs/` ao
lado da config, por isso elas ficam aqui e não em `rtl/`: nada de saída de
síntese no meio dos fontes.

Método, igual ao dos blocos já documentados em `docs/`: `USE_SLANG`,
`SYNTH_ABC_BUFFERING`, relógio de 25 ns e o SDC genérico do LibreLane (5 ns de
atraso externo na entrada e na saída, que é o padrão a 25 ns).

Diferença: aqui o die é **relativo** (`FP_SIZING: relative`, `FP_CORE_UTIL`),
e não um `DIE_AREA` absoluto. O LibreLane dimensiona o bloco a partir da área
sintetizada, o que evita escolher 400x400 ou 900x900 a dedo por bloco. As
folgas de tempo e os resultados de DRC/LVS/antena se leem do mesmo jeito; o
que não é comparável diretamente com os docs é a área do die e a contagem de
avisos de slew, que dependem do tamanho escolhido.
