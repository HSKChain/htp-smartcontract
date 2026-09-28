from __future__ import annotations

import unittest

from coincurve import PrivateKey

import consumer


class ConsumerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        consumer.require_pinned_runtime()

    def test_manifests_and_vectors(self) -> None:
        consumer.verify_identifier_vectors()
        consumer.verify_manifests()
        consumer.verify_eip712_vectors()
        consumer.verify_settlement_vectors()

    def test_deployment_version_contract(self) -> None:
        for valid in ("0.0.0", "1.2.3"):
            self.assertTrue(consumer.is_canonical_deployment_version(valid))
        for invalid in (
            "v1.2.3",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.2",
            "1.2.3-beta",
            "1.2.3+build",
            "Café",
            "",
        ):
            self.assertFalse(consumer.is_canonical_deployment_version(invalid))

    def test_all_portable_boundary_cases_execute(self) -> None:
        consumer.verify_boundary_contracts()
        self.assertEqual(
            consumer.boundary_case_counts(),
            {
                "Quote": {"positive": 2, "negative": 4},
                "Inventory": {"positive": 3, "negative": 2},
                "Fee TCB": {"positive": 1, "negative": 4},
                "KMS/Executor": {"positive": 7, "negative": 8},
                "Finality": {"positive": 4, "negative": 4},
                "Deep reorg": {"positive": 1, "negative": 2},
                "Subgraph": {"positive": 2, "negative": 4},
            },
        )

    def test_primitive_eip712_encoder(self) -> None:
        self.assertEqual(
            consumer.encode_primitive("bytes4", "0x01020304"),
            bytes.fromhex("01020304" + "00" * 28),
        )
        self.assertEqual(consumer.encode_primitive("bool", True), bytes.fromhex("00" * 31 + "01"))
        self.assertEqual(
            consumer.encode_primitive("address", "0x000000000000000000000000000000000000d001"),
            bytes.fromhex("00" * 12 + "00" * 18 + "d001"),
        )
        with self.assertRaisesRegex(ValueError, "out of range"):
            consumer.encode_primitive("uint8", "256")

    def test_struct_hash_is_recomputed_from_input(self) -> None:
        document = consumer.load_json("vectors/eip712/firm-quote.json")
        vector = document
        self.assertEqual(
            consumer.hash_struct(document["primaryType"], vector["typeString"], vector["input"]),
            vector["structHash"],
        )
        mutated = dict(vector["input"])
        mutated["quoteNonce"] = str(int(mutated["quoteNonce"]) + 1)
        self.assertNotEqual(
            consumer.hash_struct(document["primaryType"], vector["typeString"], mutated),
            vector["structHash"],
        )

    def test_static_event_decode(self) -> None:
        events = consumer.load_json("protocol/events.json")["events"]
        event = next(
            entry
            for entry in events
            if entry["name"] == "DependentDvpRegistered"
        )
        dvp = "000000000000000000000000000000000000d001"
        evidence = "00" * 31 + "11"
        actor = "000000000000000000000000000000000000b001"
        topics = [event["topic0"], f"0x{'00' * 12}{dvp}"]
        data = f"0x{31337:064x}{evidence}{'00' * 12}{actor}"
        decoded = consumer.decode_event(event, topics, data)
        self.assertEqual(decoded["chainId"], 31337)
        self.assertEqual(decoded["dvp"], f"0x{dvp}")
        self.assertEqual(decoded["evidenceHash"], f"0x{evidence}")
        self.assertEqual(decoded["actor"], f"0x{actor}")

    def test_eip712_digest_can_be_signed_and_recovered(self) -> None:
        vector = consumer.load_json("vectors/eip712/firm-quote.json")
        private_key = PrivateKey()
        signature = consumer.sign_digest(private_key, vector["digest"])
        recovered = consumer.recover_signer(vector["digest"], signature)
        self.assertEqual(recovered.format(compressed=False), private_key.public_key.format(compressed=False))

    def test_decode_rejects_wrong_topic(self) -> None:
        event = {
            "topic0": f"0x{'11' * 32}",
            "anonymous": False,
            "inputs": [],
        }
        with self.assertRaisesRegex(ValueError, "topic mismatch"):
            consumer.decode_event(event, [f"0x{'22' * 32}"], "0x")

    def test_path_traversal_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "traversal"):
            consumer.load_json("../../package.json")


if __name__ == "__main__":
    unittest.main()
