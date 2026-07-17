import re
import sys
import os

def toggle_files(mode):
    files = ["restore_sql.tf", "restore_filestore.tf", "restore.tf"]
    print(f"Toggling dependencies to: {mode}")
    
    # We will use precise line-based or content-based replacement to be safe.
    for fname in files:
        if not os.path.exists(fname):
            continue
            
        with open(fname, "r") as f:
            content = f.read()
            
        if mode == "parallel":
            # Comment out single lines in SQL and Filestore
            content = re.sub(
                r'(\s*)(dependency_gate\s*=\s*var\.enforce_dr_dependencies\s*\?\s*terraform_data\..+)',
                r'\1# \2',
                content
            )
            # Comment out blocks in restore.tf
            # Match the labels block for dependency_gate
            block_regex = r'(\s*)labels\s*\{\s*key\s*=\s*"dependency_gate"\s*value\s*=\s*var\.enforce_dr_dependencies\s*\?\s*terraform_data\.[a-zA-Z0-9_\[\]\.]+\.id\s*:\s*"none"\s*\}'
            def comment_block(match):
                spaces = match.group(1)
                lines = match.group(0).splitlines()
                commented_lines = [f"{spaces}# {line.strip()}" for line in lines]
                return "\n".join(commented_lines)
            content = re.sub(block_regex, comment_block, content)
            
        elif mode == "sequential":
            # Uncomment single lines
            content = re.sub(
                r'(\s*)#\s*(dependency_gate\s*=\s*var\.enforce_dr_dependencies\s*\?\s*terraform_data\..+)',
                r'\1\2',
                content
            )
            # Uncomment blocks
            commented_block_regex = r'(\s*)#\s*labels\s*\{\s*\n\s*#\s*key\s*=\s*"dependency_gate"\s*\n\s*#\s*value\s*=\s*var\.enforce_dr_dependencies\s*\?\s*terraform_data\.[a-zA-Z0-9_\[\]\.]+\.id\s*:\s*"none"\s*\n\s*#\s*\}'
            def uncomment_block(match):
                spaces = match.group(1)
                block_content = match.group(0)
                # Strip leading hash marks
                lines = block_content.splitlines()
                uncommented_lines = []
                for line in lines:
                    stripped = line.strip()
                    if stripped.startswith("#"):
                        stripped = stripped[1:].strip()
                    uncommented_lines.append(f"{spaces}{stripped}")
                return "\n".join(uncommented_lines)
            content = re.compile(commented_block_regex).sub(uncomment_block, content)
            
        with open(fname, "w") as f:
            f.write(content)
        print(f"Updated {fname}")

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ["parallel", "sequential"]:
        print("Usage: python3 toggle_dependencies.py [parallel|sequential]")
        sys.exit(1)
    toggle_files(sys.argv[1])
