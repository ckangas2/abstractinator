import subprocess
import json
import sys
import os

# Configuration - STRICTLY bound to the FINAL directory
BASE_DIR = "/home/viridaex/.openclaw/workspace/workspace-code-team/ABSTRACTINATOR_FINAL"
CLI_PATH = os.path.join(BASE_DIR, "abstractinator.sh")

def run_command(cmd_list):
    """Executes a subprocess securely without shell=True to prevent injection."""
    try:
        result = subprocess.run(
            cmd_list, 
            capture_output=True, 
            text=True, 
            check=True,
            cwd=BASE_DIR
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        return json.dumps({"error": f"Command failed: {e.stderr}"})

def abstractinator(action, **kwargs):
    """
    The core bridge function for OpenClaw.
    Actions: 'sweep', 'gap', 'query'
    """
    if action == "sweep":
        query = kwargs.get("query")
        if not query: return json.dumps({"error": "Query is required for sweep"})
        # Safely passing arguments as a list
        return run_command([CLI_PATH, "-s", query])

    elif action == "gap":
        topic = kwargs.get("topic")
        if not topic: return json.dumps({"error": "Topic is required for gap analysis"})
        return run_command([CLI_PATH, "-g", topic])

    elif action == "query":
        sql = kwargs.get("sql")
        if not sql: return json.dumps({"error": "SQL query is required"})
        return run_command([CLI_PATH, "-q", sql])

    else:
        return json.dumps({"error": f"Unsupported action: {action}"})

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: python abstractinator_bridge.py [action] [value]"}))
        sys.exit(1)

    action = sys.argv[1]
    val = sys.argv[2]

    if action == "sweep": print(abstractinator("sweep", query=val))
    elif action == "gap": print(abstractinator("gap", topic=val))
    elif action == "query": print(abstractinator("query", sql=val))
    else: print(json.dumps({"error": "Invalid action"}))
