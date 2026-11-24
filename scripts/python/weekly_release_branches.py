"""Prints the branch each plugin-dev-release.yml call in the given workflow files releases from:
its release-branch, or * for N.x-dev. Exits 3 when no job calls it, and 1 with the error on stdout
when a workflow cannot be read or a release-branch is unusable.
Usage: weekly_release_branches.py <uses-target> <workflow-file>..."""
import sys, yaml
target = sys.argv[1]
found = False
release_branches = []

def fail(message):
    # On stdout, the only stream the caller captures for its error.
    print(message)
    sys.exit(1)

for path in sys.argv[2:]:
    try:
        with open(path, encoding='utf-8') as handle:
            doc = yaml.safe_load(handle)
    except (OSError, UnicodeDecodeError, ValueError, yaml.YAMLError) as error:
        fail(f'{path}: {error}')
    jobs = doc.get('jobs') if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        continue
    for job in jobs.values():
        uses = job.get('uses') if isinstance(job, dict) else None
        if isinstance(uses, str) and '@' in uses and (uses.split('@', 1)[0] + '@').endswith(target):
            found = True
            inputs = job.get('with')
            branch = inputs.get('release-branch') if isinstance(inputs, dict) else None
            if isinstance(branch, str) and '${{' in branch:
                fail(f'{path}: release-branch must be a literal branch name for the date check, not {branch}')
            if branch is not None and not isinstance(branch, str):
                # YAML reads 1.10 as the number 1.1, so the branch name is already lost.
                fail(f'{path}: quote release-branch, it is read as {branch!r}')
            # '*' cannot be a branch name, so it marks a call that releases from N.x-dev.
            release_branches.append(branch if isinstance(branch, str) and branch else '*')
if not found:
    sys.exit(3)
print('\n'.join(release_branches))
