import unittest

from hosted_cua_prompt import PromptFault, prompt_button, prompt_click_arguments, prompt_matches, validate_schema


class PromptMatchTests(unittest.TestCase):
    def test_requires_exact_certificate_identity_and_root_consent(self):
        window = {"accessibility_tree": {"text": "Add Certificate Ticket569 unique, thumbprint 0123 4567 89AB CDEF to Root store?"}}
        self.assertTrue(prompt_matches(window, "Ticket569 unique", "0123456789ABCDEF"))
        self.assertFalse(prompt_matches(window, "Ticket569 other", "0123456789ABCDEF"))
        self.assertFalse(prompt_matches(window, "Ticket569 unique", "FFFFFFFFFFFFFFFF"))
        self.assertFalse(prompt_matches({"text": "Install Ticket569 unique 0123456789ABCDEF certificate?"}, "Ticket569 unique", "0123456789ABCDEF"))

    def test_selects_only_unique_enabled_affirmative_button_from_snapshot(self):
        snapshot = {"text": "Add Certificate Ticket569 unique, thumbprint 0123 4567 89AB CDEF to Root store?", "elements": [
            {"role": "button", "label": "Yes", "enabled": True, "element_token": "s00000001:2"},
            {"role": "button", "label": "No", "enabled": True, "element_token": "s00000001:3"},
        ]}
        self.assertEqual(prompt_button(snapshot, "Ticket569 unique", "0123456789ABCDEF"), "s00000001:2")
        snapshot["elements"].append({"role": "button", "label": "Install", "enabled": True, "element_token": "s00000001:4"})
        self.assertIsNone(prompt_button(snapshot, "Ticket569 unique", "0123456789ABCDEF"))
        self.assertIsNone(prompt_button({"elements": [{"role": "button", "label": "Yes", "enabled": False, "element_token": "s00000001:2"}]}, "Ticket569 unique", "0123456789ABCDEF"))

    def test_mcp_arguments_are_checked_against_advertised_schema(self):
        schema = {
            "type": "object", "additionalProperties": False,
            "required": ["target"], "properties": {
                "target": {"oneOf": [
                    {"type": "object", "required": ["kind", "pid", "window_id"], "properties": {"kind": {"const": "window"}, "pid": {"type": "integer"}, "window_id": {"type": "integer"}}},
                    {"type": "object", "required": ["kind", "display_id"], "properties": {"kind": {"const": "desktop"}, "display_id": {"type": "string"}}},
                ]}
            },
        }
        validate_schema(schema, {"target": {"kind": "window", "pid": 42, "window_id": 17}})
        for arguments in (
            {},
            {"target": {"kind": "window", "pid": 42}},
            {"target": {"kind": "desktop", "display_id": "primary"}, "unadvertised": True},
        ):
            with self.subTest(arguments=arguments), self.assertRaises(PromptFault):
                validate_schema(schema, arguments)

    def test_prompt_click_is_bound_to_observed_process_and_window(self):
        self.assertEqual(prompt_click_arguments({
            "pid": 42, "windowId": 17, "affirmativeElementToken": "s00000001:2",
        }), {"pid": 42, "window_id": 17, "element_token": "s00000001:2"})


if __name__ == "__main__":
    unittest.main()
