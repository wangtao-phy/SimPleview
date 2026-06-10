import json

log_file = "/Users/wangtao/.gemini/antigravity/brain/314b8b82-c2b8-463e-bfa7-00c7f0e03af2/.system_generated/logs/transcript.jsonl"
files_touched = set()

with open(log_file, "r") as f:
    for line in f:
        try:
            data = json.loads(line)
            if "tool_calls" in data:
                for call in data["tool_calls"]:
                    if call["function"] in ("replace_file_content", "multi_replace_file_content"):
                        args = json.loads(call["arguments"])
                        if "TargetFile" in args:
                            files_touched.add(args["TargetFile"])
        except Exception as e:
            pass

print("Files modified:")
for f in files_touched:
    print(f)
