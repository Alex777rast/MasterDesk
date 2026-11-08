import unittest
import request_state as r


class RequestStateTests(unittest.TestCase):
    def setUp(self):
        self.intent = r.intent('a'*40, 110, 'b'*64, 'payload', 'c'*64)

    def test_deterministic_bound_intent(self):
        self.assertEqual(self.intent, r.intent('a'*40, 110, 'b'*64, 'payload', 'c'*64))
        self.assertNotEqual(self.intent['key'], r.intent('a'*40, 110, 'b'*64, 'outer', 'c'*64)['key'])

    def test_new_never_directly_submits(self):
        self.assertEqual(r.next_action(self.intent, None), 'PERSIST_INTENT')

    def test_timeout_or_crash_requires_reconciliation(self):
        self.assertEqual(r.next_action(self.intent, {'intent': self.intent, 'status': 'intent'}),
                         'RECONCILE_UNKNOWN_SUBMISSION')

    def test_resume_same_request_no_second_submit(self):
        for status, action in [('pending', 'POLL_EXISTING_REQUEST'), ('completed', 'VERIFY_EXISTING_RESULT'),
                               ('denied', 'STOP'), ('failed', 'STOP'), ('cancelled', 'STOP')]:
            with self.subTest(status=status):
                self.assertEqual(r.next_action(self.intent, {'intent': self.intent, 'status': status,
                                                             'requestId': 'synthetic-123'}), action)

    def test_changed_input_or_policy_rejected(self):
        other = r.intent('a'*40, 110, 'd'*64, 'payload', 'c'*64)
        with self.assertRaises(ValueError):
            r.next_action(self.intent, {'intent': other, 'status': 'pending', 'requestId': 'fixture'})

    def test_missing_id_unknown_state_fail_closed(self):
        for doc in ({'status': 'pending'}, {'status': 'unknown', 'requestId': 'fixture'},
                    {'status': 'pending', 'requestId': 'bad\n'}):
            with self.subTest(doc=doc), self.assertRaises(ValueError):
                r.next_action(self.intent, dict(doc, intent=self.intent))
