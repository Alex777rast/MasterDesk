"""Inert future submission guard. No API, token, approval or signing operation.

The activation implementation must persist an intent BEFORE submitting, under
an exclusive durable lock/CAS, and reconcile unknown outcomes with SignPath.
This model alone is not a durable provider integration.
"""
import hashlib
import json
import re
from pipeline import COMMIT, HASH


def intent(commit, beta, artifact_sha256, stage, policy_fingerprint):
    if (not COMMIT.fullmatch(commit) or type(beta) is not int or not 110 <= beta <= 65535 or
        not HASH.fullmatch(artifact_sha256) or stage not in ('payload', 'outer') or
        not HASH.fullmatch(policy_fingerprint)):
        raise ValueError('Invalid exact signing intent')
    doc = {'commit': commit, 'beta': beta, 'inputSha256': artifact_sha256,
           'stage': stage, 'policySha256': policy_fingerprint}
    doc['key'] = hashlib.sha256(json.dumps(doc, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return doc


def next_action(expected, persisted):
    if persisted is None:
        # Not SUBMIT: persist intent under an exclusive lock before the HTTP POST.
        return 'PERSIST_INTENT'
    if persisted.get('intent') != expected:
        raise ValueError('Different bytes/source/policy under existing request state')
    status = persisted.get('status')
    request_id = persisted.get('requestId')
    if status == 'intent' and request_id is None:
        return 'RECONCILE_UNKNOWN_SUBMISSION'  # never resubmit after timeout/crash
    if not isinstance(request_id, str) or not re.fullmatch(r'[A-Za-z0-9-]{1,128}', request_id):
        raise ValueError('Exact provider request ID required')
    if status == 'pending':
        return 'POLL_EXISTING_REQUEST'
    if status == 'completed':
        return 'VERIFY_EXISTING_RESULT'
    if status in ('denied', 'failed', 'cancelled'):
        return 'STOP'
    raise ValueError('Unknown provider state; do not submit')
