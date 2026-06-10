import json

log_file = "/Users/wangtao/.gemini/antigravity/brain/314b8b82-c2b8-463e-bfa7-00c7f0e03af2/.system_generated/logs/transcript.jsonl"
edits = []

with open(log_file, "r") as f:
    for line in f:
        try:
            data = json.loads(line)
            if "tool_calls" in data:
                for call in data["tool_calls"]:
                    name = call.get("name") or call.get("function", {}).get("name")
                    if name in ("replace_file_content", "multi_replace_file_content"):
                        args_raw = call.get("args", {})
                        if not args_raw and "arguments" in call.get("function", {}):
                            args_raw = json.loads(call["function"]["arguments"])
                        args = {}
                        for k, v in args_raw.items():
                            try:
                                args[k] = json.loads(v)
                            except:
                                args[k] = v
                        edits.append(args)
        except Exception as e:
            pass

print(f"Found {len(edits)} edits.")
for e in reversed(edits):
    target_file = e.get("TargetFile")
    if not target_file or "task.md" in target_file or "walkthrough.md" in target_file:
        continue
    try:
        with open(target_file, "r") as f:
            content = f.read()
        
        chunks = e.get("ReplacementChunks", [])
        if isinstance(chunks, str):
            chunks = json.loads(chunks)
        if "TargetContent" in e and "ReplacementContent" in e:
            chunks = [{"TargetContent": e["TargetContent"], "ReplacementContent": e["ReplacementContent"]}]
        
        changed = False
        for chunk in reversed(chunks):
            t_content = chunk.get("TargetContent", "")
            r_content = chunk.get("ReplacementContent", "")
            if r_content in content:
                content = content.replace(r_content, t_content, 1)
                changed = True
        
        if changed:
            with open(target_file, "w") as f:
                f.write(content)
            print(f"Reversed edit in {target_file}")
    except Exception as err:
        print(f"Error reversing {target_file}: {err}")
