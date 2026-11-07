"""Validate collected CycloneDX against official 1.5 JSON Schema; no inference."""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen
import jsonschema
from referencing import Registry, Resource


def main(sbom, output):
    hashes = {}
    def retrieve(uri):
        if not uri.startswith('https://cyclonedx.org/schema/'):
            raise ValueError('Unexpected schema origin')
        with urlopen(Request(uri, headers={'User-Agent':'MasterDesk-SBOM-validation'}), timeout=30) as response:
            raw = response.read(4*1024*1024)
        hashes[uri] = hashlib.sha256(raw).hexdigest()
        return Resource.from_contents(json.loads(raw))
    uri = 'https://cyclonedx.org/schema/bom-1.5.schema.json'
    resource = retrieve(uri)
    registry = Registry(retrieve=retrieve).with_resource(uri, resource)
    schema = resource.contents
    doc = json.loads(sbom.read_text(encoding='utf-8'))
    jsonschema.Draft7Validator.check_schema(schema)
    validator = jsonschema.Draft7Validator(schema, registry=registry)
    errors = sorted(validator.iter_errors(doc), key=lambda e: str(e.path))
    refs = [c['bom-ref'] for c in doc['components']]
    if len(set(refs)) != len(refs):
        raise ValueError('Duplicate component reference')
    for edge in doc['dependencies']:
        if edge['ref'] not in refs or any(x not in refs for x in edge['dependsOn']):
            raise ValueError('Dangling dependency reference')
    if errors:
        raise ValueError('; '.join(str(e.path)+': '+e.message[:200] for e in errors[:5]))
    with output.open('x', encoding='utf-8') as f:
        json.dump({'status':'PASS','schema':uri,'schemaSha256':hashes,
                   'components':len(refs),'dependencyNodes':len(doc['dependencies']),
                   'meaning':'Schema/reference integrity only; not completeness, linkage or legal clearance'},f,indent=2)
    print('PASS CycloneDX1.5 schema and dependency references')


if __name__ == '__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--sbom',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    main(**vars(ap.parse_args()))
