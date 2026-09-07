export async function probe(ctx) {
  await ctx.check('probe/liveness', async () => {
    const { body } = await ctx.client.request('GET', '/health', { key: null, expected: 200 });
    ctx.require(body.status === 'ok', 'Liveness is not ok');
  });
  await ctx.check('probe/readiness', async () => {
    const { body } = await ctx.client.request('GET', '/health/ready', { key: null, expected: 200 });
    ctx.require(body.status === 'ok' && body.checks?.database === 'ok', 'Database readiness is not ok');
  });
}
