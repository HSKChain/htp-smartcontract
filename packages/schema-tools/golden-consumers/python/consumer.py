"""Portable read-only consumer for schema/v1 JSON artifacts."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

from coincurve import PrivateKey, PublicKey
from Crypto.Hash import keccak

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
SCHEMA_ROOT = REPOSITORY_ROOT / "schema" / "v1"
OFFCHAIN_ROOT = REPOSITORY_ROOT / "schema" / "off-chain" / "v1"
PINNED_PYTHON = (3, 12, 11)


def require_pinned_runtime() -> None:
    if sys.version_info[:3] != PINNED_PYTHON:
        actual = ".".join(str(part) for part in sys.version_info[:3])
        raise RuntimeError(f"Python 3.12.11 required, found {actual}")


def load_json_from(root: Path, relative_path: str) -> Any:
    path = (root / relative_path).resolve()
    if root.resolve() not in path.parents:
        raise ValueError("schema path traversal rejected")
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_json(relative_path: str) -> Any:
    return load_json_from(SCHEMA_ROOT, relative_path)


def load_offchain(relative_path: str) -> Any:
    return load_json_from(OFFCHAIN_ROOT, relative_path)


def keccak256(data: bytes) -> str:
    digest = keccak.new(digest_bits=256)
    digest.update(data)
    return f"0x{digest.hexdigest()}"


def selector(signature: str) -> str:
    return keccak256(signature.encode("utf-8"))[:10]


def typed_data_digest(domain_separator: str, struct_hash: str) -> str:
    payload = b"\x19\x01" + bytes.fromhex(domain_separator[2:]) + bytes.fromhex(struct_hash[2:])
    return keccak256(payload)


def _hex_bytes(value: str) -> bytes:
    if not isinstance(value, str) or not value.startswith("0x") or len(value) % 2 != 0:
        raise ValueError("canonical 0x-prefixed hex required")
    try:
        return bytes.fromhex(value[2:])
    except ValueError as error:
        raise ValueError("invalid hex value") from error


def parse_type_string(type_string: str) -> dict[str, list[tuple[str, str]]]:
    definitions: dict[str, list[tuple[str, str]]] = {}
    matches = list(re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\(([^)]*)\)", type_string))
    if not matches or "".join(match.group(0) for match in matches) != type_string:
        raise ValueError("malformed canonical EIP-712 type string")
    for match in matches:
        fields: list[tuple[str, str]] = []
        if match.group(2):
            for declaration in match.group(2).split(","):
                parts = declaration.split(" ")
                if len(parts) != 2 or not all(parts):
                    raise ValueError("malformed EIP-712 field declaration")
                fields.append((parts[0], parts[1]))
        if match.group(1) in definitions:
            raise ValueError("duplicate EIP-712 type definition")
        definitions[match.group(1)] = fields
    return definitions


def encode_primitive(abi_type: str, value: Any) -> bytes:
    if abi_type == "string":
        if not isinstance(value, str):
            raise ValueError("string value required")
        return _hex_bytes(keccak256(value.encode("utf-8")))
    if abi_type == "bytes":
        return _hex_bytes(keccak256(_hex_bytes(value)))
    bytes_match = re.fullmatch(r"bytes([1-9]|[12][0-9]|3[0-2])", abi_type)
    if bytes_match:
        raw = _hex_bytes(value)
        size = int(bytes_match.group(1))
        if len(raw) != size:
            raise ValueError(f"{abi_type} requires exactly {size} bytes")
        return raw.ljust(32, b"\x00")
    if abi_type == "address":
        raw = _hex_bytes(value)
        if len(raw) != 20:
            raise ValueError("address requires exactly 20 bytes")
        return raw.rjust(32, b"\x00")
    uint_match = re.fullmatch(r"uint(8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?", abi_type)
    if uint_match:
        if isinstance(value, bool):
            raise ValueError("bool is not a uint")
        try:
            integer = int(value)
        except (TypeError, ValueError) as error:
            raise ValueError("canonical uint value required") from error
        width = int(uint_match.group(1) or "256")
        if integer < 0 or integer >= 1 << width:
            raise ValueError(f"{abi_type} out of range")
        return integer.to_bytes(32, "big")
    if abi_type == "bool":
        if not isinstance(value, bool):
            raise ValueError("bool value required")
        return (1 if value else 0).to_bytes(32, "big")
    raise ValueError(f"unsupported primitive EIP-712 type: {abi_type}")


def hash_struct(primary_type: str, type_string: str, value: dict[str, Any]) -> str:
    definitions = parse_type_string(type_string)
    fields = definitions.get(primary_type)
    if fields is None:
        raise ValueError(f"primary type {primary_type} absent from type string")
    expected_fields = {name for _, name in fields}
    if set(value) != expected_fields:
        raise ValueError(f"{primary_type} input field set mismatch")
    encoded = bytearray(_hex_bytes(keccak256(type_string.encode("utf-8"))))
    for abi_type, name in fields:
        if abi_type in definitions:
            raise ValueError("nested structs are outside this primitive consumer profile")
        encoded.extend(encode_primitive(abi_type, value[name]))
    return keccak256(bytes(encoded))


def sign_digest(private_key: PrivateKey, digest: str) -> bytes:
    digest_bytes = bytes.fromhex(digest[2:])
    if len(digest_bytes) != 32:
        raise ValueError("signing digest must contain 32 bytes")
    return private_key.sign_recoverable(digest_bytes, hasher=None)


def recover_signer(digest: str, signature: bytes) -> PublicKey:
    digest_bytes = bytes.fromhex(digest[2:])
    if len(digest_bytes) != 32 or len(signature) != 65:
        raise ValueError("invalid recoverable signature input")
    return PublicKey.from_signature_and_message(signature, digest_bytes, hasher=None)


def decode_static_word(abi_type: str, word: bytes) -> Any:
    if len(word) != 32:
        raise ValueError("ABI word must contain 32 bytes")
    if abi_type == "address":
        if any(word[:12]):
            raise ValueError("non-canonical address word")
        return f"0x{word[12:].hex()}"
    if abi_type.startswith("uint"):
        return int.from_bytes(word, "big")
    if abi_type == "bool":
        value = int.from_bytes(word, "big")
        if value not in (0, 1):
            raise ValueError("non-canonical bool word")
        return value == 1
    if abi_type == "bytes32":
        return f"0x{word.hex()}"
    raise ValueError(f"unsupported portable static type: {abi_type}")


def decode_event(event: dict[str, Any], topics: list[str], data: str) -> dict[str, Any]:
    expected_topic = event["topic0"]
    if event.get("anonymous", False):
        topic_index = 0
    else:
        if not topics or topics[0].lower() != expected_topic.lower():
            raise ValueError("event topic mismatch")
        topic_index = 1
    data_bytes = bytes.fromhex(data[2:])
    data_index = 0
    decoded: dict[str, Any] = {}
    for item in event["inputs"]:
        if item.get("indexed", False):
            if topic_index >= len(topics):
                raise ValueError("missing indexed topic")
            word = bytes.fromhex(topics[topic_index][2:])
            topic_index += 1
        else:
            word = data_bytes[data_index : data_index + 32]
            data_index += 32
        decoded[item["name"]] = decode_static_word(item["type"], word)
    if data_index != len(data_bytes):
        raise ValueError("trailing event data")
    return decoded


def is_canonical_deployment_version(value: str) -> bool:
    return isinstance(value, str) and re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)",
        value,
        flags=re.ASCII,
    ) is not None


def hash_deployment_version(value: str) -> str:
    if not is_canonical_deployment_version(value):
        raise ValueError("invalid canonical deployment version")
    domain = _hex_bytes(keccak256(b"HTP_DEPLOYMENT_VERSION"))
    version_hash = _hex_bytes(keccak256(value.encode("ascii")))
    return keccak256(domain + version_hash)


def verify_identifier_vectors() -> None:
    vectors = load_json("vectors/identifiers/canonical-identifiers.json")["deploymentVersion"]
    for case in vectors["positive"]:
        assert is_canonical_deployment_version(case["input"])
        assert hash_deployment_version(case["input"]) == case["deploymentVersionHash"]
    for case in vectors["negative"]:
        assert not is_canonical_deployment_version(case["input"])
        try:
            hash_deployment_version(case["input"])
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid deployment version accepted: {case['input']!r}")


def verify_manifests() -> None:
    index = load_json("index.json")
    for entry in index["files"]:
        payload = (SCHEMA_ROOT / entry["path"]).read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        if digest != entry["sha256"]:
            raise AssertionError(f"index sha256 mismatch: {entry['path']}")

    layouts = load_json("types/layouts.json")
    structs = {entry["name"]: entry for entry in layouts["structs"]}
    firm_quote = structs["FirmQuote"]
    assert firm_quote["dynamic"] is True
    assert firm_quote["headByteLength"] == 31 * 32
    price_data = next(field for field in firm_quote["fields"] if field["name"] == "priceData")
    assert price_data["dynamic"] is True
    assert price_data["headOffset"] == 13 * 32
    fee_config = structs["FeeConfig"]
    names = [field["name"] for field in fee_config["fields"]]
    assert names.index("scopeKeyHash") < names.index("matchedScopeHash")

    eip712 = load_json("protocol/eip712.json")
    for entry in eip712["types"]:
        assert keccak256(entry["typeString"].encode("utf-8")) == entry["typeHash"]

    errors = load_json("protocol/errors.json")
    assert errors["generatedFrom"].startswith("compiled production ABI")
    for entry in errors["errors"]:
        assert selector(entry["signature"]) == entry["selector"]
        assert entry["sources"] and all(source.startswith("src/") for source in entry["sources"])

    events = load_json("protocol/events.json")
    assert events["generatedFrom"].startswith("compiled production ABI")
    for entry in events["events"]:
        assert keccak256(entry["signature"].encode("utf-8")) == entry["topic0"]
        assert entry["sources"] and all(source.startswith("src/") for source in entry["sources"])

    configs = load_json("protocol/configs.json")
    namespaces = configs["sourceConstants"]["configIdNamespaces"]
    for value in namespaces.values():
        assert keccak256(value["preimage"].encode("utf-8")) == value["namespaceHash"]
    for formula in configs["idFormulas"]:
        constant = formula["namespaceConstant"]
        assert constant is None or constant in namespaces
    fee_scope = configs["sourceConstants"]["feeScope"]
    assert configs["feeScope"]["sourceConstant"] == fee_scope["constant"]
    assert keccak256(fee_scope["typeString"].encode("utf-8")) == fee_scope["typeHash"]


def verify_eip712_vectors() -> None:
    manifest_types = {
        entry["typeString"].split("(", 1)[0]: entry
        for entry in load_json("protocol/eip712.json")["types"]
    }
    domain_vector = load_json("vectors/eip712/domain.json")
    assert keccak256(domain_vector["typeString"].encode("utf-8")) == domain_vector["typeHash"]
    assert domain_vector["typeHash"] == manifest_types["EIP712Domain"]["typeHash"]
    domain_hash = hash_struct("EIP712Domain", domain_vector["typeString"], domain_vector["input"])
    assert domain_hash == domain_vector["separator"]
    assert domain_hash == keccak256(
        _hex_bytes(domain_vector["typeHash"])
        + encode_primitive("string", domain_vector["input"]["name"])
        + encode_primitive("string", domain_vector["input"]["version"])
        + encode_primitive("uint256", domain_vector["input"]["chainId"])
        + encode_primitive("address", domain_vector["input"]["verifyingContract"])
    )

    for filename in (
        "firm-quote.json",
        "trade-intent.json",
        "nonce-cancellation.json",
        "trade-terms-snapshot.json",
    ):
        vector = load_json(f"vectors/eip712/{filename}")
        primary_type = vector["primaryType"]
        computed_type_hash = keccak256(vector["typeString"].encode("utf-8"))
        computed_struct_hash = hash_struct(primary_type, vector["typeString"], vector["input"])
        expected_struct_hash = vector.get("structHash", vector.get("hash"))
        assert computed_type_hash == vector["typeHash"]
        assert computed_type_hash == manifest_types[primary_type]["typeHash"]
        assert computed_struct_hash == expected_struct_hash
        if primary_type == "TradeTermsSnapshot":
            assert typed_data_digest(domain_hash, computed_struct_hash) == vector["eip712DigestIfMisused"]
        else:
            assert vector["domainSeparator"] == domain_hash
            assert typed_data_digest(domain_hash, computed_struct_hash) == vector["digest"]


class ContractViolation(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def validate_quote_lifecycle(case: dict[str, Any]) -> str:
    if len(set(case["proposedHashes"])) > 1:
        raise ContractViolation("SECOND_PROPOSED_HASH_FORBIDDEN")
    state = case["initialState"]
    for action in case["actions"]:
        if state == "ACTIVE_FIRM" and action == "RESERVE":
            state = "RESERVED"
        elif state == "RESERVED" and action == "CONSUME":
            if not case["canonicalSnapshotHash"] or not case["canonicalSnapshotSignatureVerified"]:
                raise ContractViolation("CANONICAL_SNAPSHOT_SIGNATURE_REQUIRED")
            state = "CONSUMED"
        elif state == "RESERVED" and action == "EXPIRE":
            state = "EXPIRED"
        elif state == "RESERVED" and action == "CANCEL":
            raise ContractViolation("RESERVED_CANNOT_CANCEL")
        elif state == "RESERVED" and action == "ROLLBACK_ACTIVE_FIRM":
            raise ContractViolation("RESERVED_CANNOT_ROLLBACK")
        else:
            raise ContractViolation("INVALID_QUOTE_TRANSITION")
    return state


def validate_inventory_contract(case: dict[str, Any]) -> str:
    if sum(int(value) for value in case["concurrentHolds"]) > int(case["availableQuantity"]):
        raise ContractViolation("CONCURRENT_HOLD_EXCEEDS_AVAILABLE")
    release = int(case["maxQuantity"]) - int(case["finalQuantity"])
    if release < 0 or release != int(case["expectedReleaseQuantity"]):
        raise ContractViolation("MAX_FINAL_DIFFERENCE_INVALID")
    state = case["initialState"]
    for action in case["actions"]:
        if state == "HELD" and action == "COMMIT":
            state = "COMMITTED"
        elif action == "RELEASE" and case["tradeStatus"] == "SIGNED":
            raise ContractViolation("SIGNED_INVENTORY_EARLY_RELEASE")
        elif state in {"HELD", "COMMITTED"} and action == "RELEASE_FINALIZED" and case["tradeStatus"] == "FINALIZED":
            state = "RELEASED"
        elif state == "HELD" and action == "RELEASE":
            state = "RELEASED"
        else:
            raise ContractViolation("INVALID_INVENTORY_TRANSITION")
    return state


def validate_fee_contract(case: dict[str, Any]) -> None:
    if case["callerSelectedScope"] is not None:
        raise ContractViolation("CALLER_SCOPE_SELECTION_FORBIDDEN")
    operation = case["operation"]
    if case["status"] == "DEPRECATED" and operation in {"GENERATE", "SIGN", "BROADCAST"}:
        raise ContractViolation(f"DEPRECATED_{operation}_FORBIDDEN")
    if operation == "SETTLE":
        evidence = case["evidence"]
        if int(evidence["signedAt"]) >= int(evidence["deprecatedAt"]):
            raise ContractViolation("PRE_DEPRECATION_SIGNATURE_EVIDENCE_REQUIRED")


def _rlp_encode(value: Any) -> bytes:
    if isinstance(value, list):
        payload = b"".join(_rlp_encode(item) for item in value)
        if len(payload) <= 55:
            return bytes([0xC0 + len(payload)]) + payload
        length = len(payload).to_bytes((len(payload).bit_length() + 7) // 8, "big")
        return bytes([0xF7 + len(length)]) + length + payload
    if isinstance(value, int):
        if value < 0:
            raise ValueError("RLP integer must be unsigned")
        value = b"" if value == 0 else value.to_bytes((value.bit_length() + 7) // 8, "big")
    if not isinstance(value, bytes):
        raise ValueError("RLP value must be bytes, int, or list")
    if len(value) == 1 and value[0] < 0x80:
        return value
    if len(value) <= 55:
        return bytes([0x80 + len(value)]) + value
    length = len(value).to_bytes((len(value).bit_length() + 7) // 8, "big")
    return bytes([0xB7 + len(length)]) + length + value


def serialize_unsigned_envelope(transaction_type: str, envelope: dict[str, Any]) -> str:
    if transaction_type == "LEGACY":
        fields = [
            int(envelope["nonce"]),
            int(envelope["gasPrice"]),
            int(envelope["gasLimit"]),
            _hex_bytes(envelope["to"]),
            int(envelope["value"]),
            _hex_bytes(envelope["data"]),
            int(envelope["chainId"]),
            0,
            0,
        ]
        return f"0x{_rlp_encode(fields).hex()}"
    if transaction_type == "TYPE2":
        if envelope["accessList"] != []:
            raise ContractViolation("TYPE2_ACCESS_LIST_MUST_BE_EMPTY")
        fields = [
            int(envelope["chainId"]),
            int(envelope["nonce"]),
            int(envelope["maxPriorityFeePerGas"]),
            int(envelope["maxFeePerGas"]),
            int(envelope["gasLimit"]),
            _hex_bytes(envelope["to"]),
            int(envelope["value"]),
            _hex_bytes(envelope["data"]),
            [],
        ]
        return f"0x02{_rlp_encode(fields).hex()}"
    raise ValueError(f"unsupported transaction type {transaction_type}")


def validate_kms_executor_contract(case: dict[str, Any]) -> None:
    forbidden = {"privateKey", "rawSignature", "rawTransaction", "kmsKeyId"}
    if forbidden.intersection(case):
        raise ContractViolation("FORBIDDEN_SIGNING_MATERIAL")
    kind = case["kind"]
    if kind == "UNSIGNED_PREIMAGE":
        if case["transactionType"] == "TYPE2" and (
            case["accessList"] != [] or case["envelope"]["accessList"] != []
        ):
            raise ContractViolation("TYPE2_ACCESS_LIST_MUST_BE_EMPTY")
        if serialize_unsigned_envelope(case["transactionType"], case["envelope"]) != case["unsignedPreimage"]:
            raise ContractViolation("UNSIGNED_ENVELOPE_PREIMAGE_MISMATCH")
        if keccak256(_hex_bytes(case["unsignedPreimage"])) != case["expectedHash"]:
            raise ContractViolation("UNSIGNED_PREIMAGE_HASH_MISMATCH")
    elif kind == "SIGNING_INTENT":
        intent = case["intent"]
        if forbidden.intersection(intent) or intent["rawMaterialStored"]:
            raise ContractViolation("FORBIDDEN_SIGNING_MATERIAL")
        if intent["digestSource"] != "LOCAL_UNSIGNED_PREIMAGE":
            raise ContractViolation("UNTRUSTED_EXTERNAL_DIGEST")
        if intent["hashPasses"] != 1:
            raise ContractViolation("DIGEST_MUST_BE_SINGLE_KECCAK")
        if intent["messageType"] != "DIGEST" or intent["prehashed"] is not True:
            raise ContractViolation("DIGEST_PREHASHED_SEMANTICS_REQUIRED")
        if not intent["opaqueRawReference"].startswith("opaque-ref:"):
            raise ContractViolation("OPAQUE_RAW_REFERENCE_REQUIRED")
    elif kind == "RAW_REFERENCE":
        if case["rawMaterialStored"] or not case["opaqueRawReference"].startswith("opaque-ref:"):
            raise ContractViolation("OPAQUE_RAW_REFERENCE_REQUIRED")
    elif kind == "REPLACEMENT":
        if case["previous"]["generation"] != case["replacement"]["generation"]:
            raise ContractViolation("REPLACEMENT_GENERATION_MISMATCH")
        if case["previous"]["nonce"] != case["replacement"]["nonce"]:
            raise ContractViolation("REPLACEMENT_NONCE_MISMATCH")
        if int(case["replacement"]["maxFeePerGas"]) <= int(case["previous"]["maxFeePerGas"]):
            raise ContractViolation("REPLACEMENT_FEE_NOT_INCREASED")
    elif kind == "CANONICAL_REVERT_RETRY":
        if (
            int(case["retry"]["generation"]) <= int(case["previous"]["generation"])
            or int(case["retry"]["nonce"]) <= int(case["previous"]["nonce"])
        ):
            raise ContractViolation("REVERT_RETRY_REQUIRES_NEW_GENERATION_NONCE")
    elif kind == "CANCELLATION":
        if case["active"]["generation"] != case["cancellation"]["generation"]:
            raise ContractViolation("CANCELLATION_GENERATION_MISMATCH")
        if case["active"]["nonce"] != case["cancellation"]["nonce"]:
            raise ContractViolation("CANCELLATION_NONCE_MISMATCH")
        if not case["cancellation"]["toSelf"] or case["cancellation"]["value"] != "0":
            raise ContractViolation("CANCELLATION_ENVELOPE_INVALID")
    else:
        raise ValueError(f"unknown KMS/Executor case kind {kind}")


def validate_finality_contract(case: dict[str, Any], threshold: int) -> str:
    requested = case["requestedState"]
    if requested == "FINAL_FROM_SUBGRAPH":
        raise ContractViolation("SUBGRAPH_NOT_FINALITY_AUTHORITY")
    if not case["receiptCanonical"]:
        if requested == "ROLLBACK_CONFIRMING":
            return "CONFIRMING"
        if requested == "KEEP_FINAL":
            raise ContractViolation("SHALLOW_REORG_REQUIRES_ROLLBACK")
        raise ContractViolation("CANONICAL_RECEIPT_REQUIRED")
    if requested == "FINAL" and int(case["confirmations"]) < threshold:
        raise ContractViolation("CONFIRMATION_THRESHOLD_NOT_MET")
    return requested


def validate_deep_reorg_contract(case: dict[str, Any]) -> dict[str, Any]:
    before = case["before"]
    operation = case["operation"]
    if operation["deleteHistoryIds"]:
        raise ContractViolation("HISTORY_DELETE_FORBIDDEN")
    if operation["appendCorrectionRecord"] is None:
        raise ContractViolation("CORRECTION_RECORD_REQUIRED")
    return {
        "history": [*before["history"], operation["appendCorrectionRecord"]],
    }


def validate_subgraph_contract(case: dict[str, Any]) -> str:
    if case["eventKind"] == "PROJECT":
        chain_positions = [index for index, item in enumerate(case["inputs"]) if item["name"] == "chainId"]
        if not chain_positions:
            raise ContractViolation("PROJECT_EVENT_CHAIN_ID_REQUIRED")
        if chain_positions != [0]:
            raise ContractViolation("PROJECT_EVENT_CHAIN_ID_MUST_BE_FIRST")
        if case["inputs"][0]["value"] != case["networkContextChainId"]:
            raise ContractViolation("PROJECT_EVENT_CHAIN_ID_MISMATCH")
        return case["inputs"][0]["value"]
    if case["eventKind"] == "OZ_STANDARD":
        if case["networkContextChainId"] is None:
            raise ContractViolation("OZ_EVENT_NETWORK_CHAIN_ID_REQUIRED")
        if any(item["name"] == "chainId" for item in case["inputs"]):
            raise ContractViolation("OZ_EVENT_ABI_MUST_NOT_BE_WRAPPED")
        return case["networkContextChainId"]
    raise ValueError("unknown subgraph event kind")


def _mutate(base: dict[str, Any], mutation: dict[str, Any]) -> dict[str, Any]:
    value = json.loads(json.dumps(base))
    if "removeField" in mutation:
        value.pop(mutation["removeField"], None)
    elif "setField" in mutation:
        value[mutation["setField"]] = mutation["value"]
    elif "addField" in mutation:
        value[mutation["addField"]] = "runtime-only-placeholder"
    elif "removeDeepReorgField" in mutation:
        value["deepReorg"].pop(mutation["removeDeepReorgField"], None)
    else:
        raise ValueError("unknown boundary mutation")
    return value


def _expect_violation(expected: str, operation: Any) -> None:
    try:
        operation()
    except ContractViolation as error:
        assert error.code == expected
    else:
        raise AssertionError(f"expected contract violation {expected}")


def verify_boundary_contracts() -> None:
    quote = load_offchain("quote.json")
    for case in quote["positive"]:
        assert validate_quote_lifecycle(case) == case["expectedState"]
    for case in quote["negative"]:
        _expect_violation(case["expectedError"], lambda case=case: validate_quote_lifecycle(case))

    inventory = load_offchain("inventory.json")
    for case in inventory["positive"]:
        assert validate_inventory_contract(case) == case["expectedState"]
    for case in inventory["negative"]:
        _expect_violation(case["expectedError"], lambda case=case: validate_inventory_contract(case))

    fee = load_offchain("fee-tcb.json")
    for case in fee["positive"]:
        validate_fee_contract(case)
    for case in fee["negative"]:
        _expect_violation(case["expectedError"], lambda case=case: validate_fee_contract(case))

    kms = load_offchain("kms-executor.json")
    for case in kms["positive"]:
        validate_kms_executor_contract(case)
    for case in kms["negative"]:
        candidate = case
        if "mutation" in case:
            candidate = _mutate(case, case["mutation"])
        _expect_violation(
            case["expectedError"],
            lambda candidate=candidate: validate_kms_executor_contract(candidate),
        )

    finality = load_offchain("finality.json")
    threshold = int(finality["confirmationThreshold"])
    for case in finality["positive"]:
        assert validate_finality_contract(case, threshold) == case["expectedState"]
    for case in finality["negative"]:
        _expect_violation(
            case["expectedError"],
            lambda case=case: validate_finality_contract(case, threshold),
        )

    reorg = load_offchain("deep-reorg.json")
    for case in reorg["positive"]:
        assert validate_deep_reorg_contract(case) == case["expected"]
    for case in reorg["negative"]:
        _expect_violation(case["expectedError"], lambda case=case: validate_deep_reorg_contract(case))

    subgraph = load_offchain("subgraph.json")
    for case in subgraph["positive"]:
        assert validate_subgraph_contract(case) == case["expectedChainId"]
    for case in subgraph["negative"]:
        _expect_violation(case["expectedError"], lambda case=case: validate_subgraph_contract(case))


def boundary_case_counts() -> dict[str, dict[str, int]]:
    files = {
        "Quote": "quote.json",
        "Inventory": "inventory.json",
        "Fee TCB": "fee-tcb.json",
        "KMS/Executor": "kms-executor.json",
        "Finality": "finality.json",
        "Deep reorg": "deep-reorg.json",
        "Subgraph": "subgraph.json",
    }
    return {
        domain: {
            "positive": len(load_offchain(filename)["positive"]),
            "negative": len(load_offchain(filename)["negative"]),
        }
        for domain, filename in files.items()
    }


def verify_settlement_vectors() -> None:
    vectors = load_json("vectors/settlement/buy-sell-permit.json")
    for case in vectors["cases"]:
        if case.get("expected", "success") != "success":
            continue
        amounts = {key: int(value) for key, value in case["amounts"].items()}
        assert amounts["buyerDebit"] == amounts["sellerCredit"] + amounts["collectorCredit"]
        assert amounts["collectorCredit"] == amounts["buyerFee"] + amounts["sellerFee"]


def main() -> None:
    require_pinned_runtime()
    verify_identifier_vectors()
    verify_manifests()
    verify_eip712_vectors()
    verify_boundary_contracts()
    verify_settlement_vectors()
    print("Python golden consumer independently verified EIP-712, catalogs, settlement, and boundaries")


if __name__ == "__main__":
    main()
