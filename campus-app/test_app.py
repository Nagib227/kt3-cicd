import os
import unittest

import app


class AppTest(unittest.TestCase):
    def test_version_default(self):
        os.environ.pop("APP_VERSION", None)
        self.assertEqual(app.version(), "0.0.0")

    def test_ready(self):
        os.environ["READY"] = "true"
        self.assertTrue(app.ready())

    def test_not_ready(self):
        os.environ["READY"] = "false"
        self.assertFalse(app.ready())


if __name__ == "__main__":
    unittest.main()
