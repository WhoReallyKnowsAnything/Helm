  // ── above the prompt: the handoff line while working; a card when a turn ends or a milestone falls
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || e.surface !== 'terminal') return next(e)
    const b = await readBoard($)
    const f = await read($, frame)
    const tick = f?.tick ?? 0
    const now = Date.now()
    const o = b.overlay
    const ui = $.ui.resolve(e)
    const { Box, Text, Raster } = ui
    const cols = Math.max(24, e.props.bodyColumns)

    if (o?.kind === 'milestone' && now - o.at < MILESTONE_OVERLAY_MS && typeof o.title === 'string') {
      const title = `★  ${o.title}  ★`
      return (
        <Box flexDirection="column">
          <Raster key="spark-a" columns={cols} rows={1} cells={sparkleCells(cols, tick, 1)} />
          <Box justifyContent="center">{shimmer(ui, title, tick, SIGNATURE, FOREGROUND, true)}</Box>
          <Box justifyContent="center">
            <Text color={hex(SECONDARY)}>LeanCTX · {o.detail}</Text>
          </Box>
          <Raster key="spark-b" columns={cols} rows={1} cells={sparkleCells(cols, tick + 7, 2)} />
        </Box>
      )
    }

    if (o?.kind === 'turn' && now - o.at < TURN_OVERLAY_MS && !b.isWorking) {
      const t = o.turn
      const gap = <Text> </Text>
      return (
        <Box flexDirection="column">
          <Raster key="sweep" columns={cols} rows={1} cells={sweepCells(cols, Math.min(1, (now - o.at) / 900), tick)} />
          <Box>
            <Text bold color={hex(OK)}>
              ✓{' '}
            </Text>
            <Text bold color={hex(FOREGROUND)}>
              Turn {t.n}
            </Text>
            <Text color={hex(SECONDARY)}> · {clock(t.durationMs)}   </Text>
            {t.sources > 0 ? pill(ui, `Claude saw ${plural(t.sources, 'source', 'sources')}`, CANVAS, SIGNATURE, true) : null}
            {t.sources > 0 && t.structure > 0 ? gap : null}
            {t.sources > 0 && t.structure > 0 ? pill(ui, `${t.structure} as structure`, FOREGROUND, PANEL) : null}
            {t.saved > 0 ? gap : null}
            {t.saved > 0 ? pill(ui, `▲ ${compact(t.saved)} tokens kept out`, FOREGROUND, BLUE_FIELD, true) : null}
            {t.sources === 0 && t.saved === 0 ? pill(ui, plural(t.calls, 'lean-ctx call', 'lean-ctx calls'), FOREGROUND, PANEL) : null}
          </Box>
        </Box>
      )
    }

    if (b.isWorking) return handoff(ui, 'band-handoff', cols, b, tick, now)
    return next(e)
  })
