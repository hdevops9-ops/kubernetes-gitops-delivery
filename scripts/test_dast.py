import unittest
from check_dast import check

class DastPolicyTests(unittest.TestCase):
    def report(self,risk,rule='999',site='http://127.0.0.1:8088'):
        return {'site':[{'@name':site,'alerts':[{'pluginid':rule,'riskcode':str(risk),'name':'test finding'}]}]}
    def test_medium_and_high_block(self):
        for risk in (2,3):
            with self.assertRaises(ValueError):check(self.report(risk))
    def test_low_reported_not_blocked(self):
        self.assertEqual(check(self.report(1))['total_alerts'],1)
    def test_empty_report_rejected(self):
        with self.assertRaises(ValueError):check({'site':[]})
    def test_tls_exception_only_for_test_loopback(self):
        check(self.report(2,'10035'))
        with self.assertRaises(ValueError):check(self.report(2,'10035','https://production.example.invalid'))
if __name__=='__main__':unittest.main()
