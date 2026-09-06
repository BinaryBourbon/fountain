// Compare advertised responses with the independently pinned projection for
// the operations this profile exercises. Compatible added properties/statuses
// are allowed. This does not replace validation of actual HTTP responses.
export function verifyAdvertisement(spec, contract, operations) {
  if (!spec.openapi?.startsWith('3.0.') || !spec.paths || !spec.components?.schemas) throw new Error('Expected an OpenAPI 3.0 document');
  const seen = new Set();
  function node(actual, expected, at) {
    if (!actual || typeof actual !== 'object') throw new Error(`${at}: advertised schema missing`);
    if (expected.ref) {
      const name = expected.ref;
      if (actual.$ref !== `#/components/schemas/${name}`) throw new Error(`${at}: advertised reference differs`);
      if (!seen.has(name)) {
        seen.add(name);
        if (!contract.schemas[name]) throw new Error(`${at}: pinned reference missing`);
        node(spec.components.schemas[name], contract.schemas[name], `schema/${name}`);
      }
      return;
    }
    for (const key of ['type', 'format']) {
      if (expected[key] !== undefined && actual[key] !== expected[key]) throw new Error(`${at}: advertised ${key} differs`);
    }
    if (Boolean(actual.nullable) !== Boolean(expected.nullable)) throw new Error(`${at}: advertised nullability differs`);
    if (expected.enum && (!Array.isArray(actual.enum) || expected.enum.some(v => !actual.enum.map(String).includes(v)))) {
      throw new Error(`${at}: advertised enum removed a value`);
    }
    for (const [name, property] of Object.entries(expected.properties ?? {})) {
      if (Boolean(property.required) !== Boolean(actual.required?.includes(name))) throw new Error(`${at}.${name}: advertised requiredness differs`);
      node(actual.properties?.[name], property, `${at}.${name}`);
    }
    if (expected.items) node(actual.items, expected.items, `${at}[]`);
    for (const keyword of ['oneOf', 'anyOf', 'allOf']) {
      if (!expected[keyword]) continue;
      if (actual[keyword]?.length !== expected[keyword].length) throw new Error(`${at}: advertised ${keyword} differs`);
      expected[keyword].forEach((member, i) => node(actual[keyword][i], member, `${at}/${keyword}/${i}`));
    }
    if (typeof expected.additionalProperties === 'object') node(actual.additionalProperties, expected.additionalProperties, `${at}.*`);
    if (typeof expected.additionalProperties === 'boolean' && actual.additionalProperties !== expected.additionalProperties) throw new Error(`${at}: advertised additional-property rule differs`);
  }
  for (const key of operations) {
    const [method, path] = key.split(' ');
    const expected = contract.operations[key];
    const actual = spec.paths[path]?.[method.toLowerCase()];
    if (!expected || !actual) throw new Error(`${key}: operation missing from pinned or advertised contract`);
    for (const [status, content] of Object.entries(expected.responses)) {
      if (!actual.responses?.[status]) throw new Error(`${key}: advertised ${status} response missing`);
      if (content['application/json']) node(actual.responses[status].content?.['application/json']?.schema, content['application/json'], `${key}/${status}`);
    }
  }
}
