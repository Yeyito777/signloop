import sys
import tempfile
import unittest

import numpy as np

try:
    import coremltools as ct
    import torch
    # coremltools ships its native converters only up to Python 3.12 (verified: 3.14 imports but cannot convert)
    HAVE = sys.version_info < (3, 13)
except Exception:          # coremltools needs Python <= 3.12 and a tested torch; see docs
    HAVE = False


@unittest.skipUnless(HAVE, "coremltools/torch unavailable in this interpreter")
class CoreMLCompatibility(unittest.TestCase):
    def test_export_matches_torch_and_output_contract(self):
        from pathlib import Path
        from recognition.export_coreml import INPUTS, convert, shapes
        from recognition.models import build_model
        torch.manual_seed(0)
        steps, n_out = 32, 7
        model = build_model("dual:concat", n_out).eval()
        ml = convert(model, steps)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "m.mlpackage"
            ml.save(str(path))
            loaded = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
            spec = loaded.get_spec()
            self.assertEqual({i.name for i in spec.description.input}, set(INPUTS))
            self.assertEqual({o.name for o in spec.description.output}, {"logits", "emb"})
            rng = np.random.default_rng(0)
            for _ in range(5):
                feed = {k: rng.normal(0, 1, shapes(steps)[k]).astype(np.float32) for k in INPUTS}
                feed["mask"] = (feed["mask"] > 0).astype(np.float32)
                with torch.no_grad():
                    ref = model({k: torch.as_tensor(v) for k, v in feed.items()})["logits"][0].numpy()
                got = np.asarray(loaded.predict(feed)["logits"]).reshape(-1)
                self.assertEqual(got.shape, (n_out,))
                self.assertLess(np.abs(ref - got).max(), 0.1)     # float16 tolerance


if __name__ == "__main__":
    unittest.main()
