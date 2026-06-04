#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_json(path: Path):
    return json.loads(read_text(path))


def extract_registry_tools(text: str) -> set[str]:
    names = set()
    for match in re.finditer(r'name\s*=\s*"([^"]+)"', text):
        names.add(match.group(1))
    return names


def find_forbidden_hardcode(text: str) -> list[str]:
    needles = [
        "создай басовую дорожку, добавь Serum, напиши бас на 8 тактов",
        "create_bass_track_with_instrument_and_midi",
        "special case",
    ]
    hits = []
    for needle in needles:
        if needle in text:
            hits.append(needle)
    return hits


def scenario_status(scenario: dict, available_tools: set[str]) -> dict:
    missing = [tool for tool in scenario.get("required_tools", []) if tool not in available_tools]
    return {
        "name": scenario["name"],
        "user_request": scenario["user_request"],
        "router": {
            "domains": scenario.get("expected_domains", []),
            "complexity": "multi_step" if len(scenario.get("required_tools", [])) > 3 else "single_step",
        },
        "selected_tools": scenario.get("required_tools", []),
        "planner_steps_count": max(len(scenario.get("required_tools", [])) - 1, 0),
        "validator_ok": len(missing) == 0,
        "executor_status": "spec_ready" if len(missing) == 0 else "blocked_by_missing_tools",
        "verified": len(missing) == 0,
        "missing_tools": missing,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Static architecture harness for the REAPER agent")
    parser.add_argument("--json", action="store_true", help="Emit JSON report")
    args = parser.parse_args()

    registry_text = read_text(ROOT / "reaper_tool_registry.lua")
    backend_text = read_text(ROOT / "reaper_agent_backend.py")
    chat_text = read_text(ROOT / "reaper_chat_agent.lua")
    scenarios = load_json(ROOT / "architecture_scenarios.json")

    available_tools = extract_registry_tools(registry_text)
    architecture_markers = {
        "router": "request_data.get(\"mode\") == \"route\"" in backend_text,
        "selected_tools": "selected_tools" in backend_text and "selected_tools" in chat_text,
        "validator": "validate_plan_locally" in chat_text,
        "executor": "execute_plan" in chat_text,
        "verify": "verify_project_state" in registry_text and "verification_checks_for_step" in chat_text,
    }
    forbidden_hits = find_forbidden_hardcode(chat_text + "\n" + backend_text)

    scenario_reports = [scenario_status(scenario, available_tools) for scenario in scenarios]
    all_ok = all(report["validator_ok"] for report in scenario_reports) and not forbidden_hits and all(architecture_markers.values())

    report = {
        "architecture_markers": architecture_markers,
        "forbidden_hardcode_hits": forbidden_hits,
        "scenario_reports": scenario_reports,
        "overall_ok": all_ok,
    }

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print("Architecture markers:")
        for name, ok in architecture_markers.items():
            print(f"- {name}: {'ok' if ok else 'missing'}")
        print()
        print("Scenario readiness:")
        for item in scenario_reports:
            status = "ok" if item["validator_ok"] else f"missing {', '.join(item['missing_tools'])}"
            print(f"- {item['name']}: {status}")
        if forbidden_hits:
            print()
            print("Forbidden hardcode hits:")
            for hit in forbidden_hits:
                print(f"- {hit}")
        print()
        print(f"overall_ok: {str(all_ok).lower()}")

    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
