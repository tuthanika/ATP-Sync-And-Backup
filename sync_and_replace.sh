#!/usr/bin/env bash
set -euxo pipefail

: "${GIT_USER_NAME:?GIT_USER_NAME is required}"
: "${GIT_USER_EMAIL:?GIT_USER_EMAIL is required}"

git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"

SELECTED_BRANCH="${SOURCE_BRANCH_MANUAL}"
if [ -z "$SELECTED_BRANCH" ]; then
  for b in main master; do
    if git ls-remote --exit-code --heads origin $b; then
      SELECTED_BRANCH="$b"
      break
    fi
  done
fi
if [ -z "$SELECTED_BRANCH" ]; then
  echo "Không tìm thấy branch main hoặc master!"
  exit 1
fi

git fetch origin "${BACKUP_BRANCH}" || true
rm -rf /tmp/backup-repo || true
if git ls-remote --exit-code --heads origin ${BACKUP_BRANCH}; then
  git worktree add /tmp/backup-repo origin/${BACKUP_BRANCH}
else
  git worktree add /tmp/backup-repo
  cd /tmp/backup-repo
  git checkout --orphan ${BACKUP_BRANCH}
  git rm -rf . || true
  git clean -fdx
  git config user.name "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
  git commit --allow-empty -m "Init backup branch"
  git push origin HEAD:refs/heads/${BACKUP_BRANCH}
  cd -
fi

cd /tmp/backup-repo
git log --pretty=format:"%H" > /tmp/backup_branch_commits.txt
cd "$GITHUB_WORKSPACE"

git checkout "$SELECTED_BRANCH"
git log --author="${BACKUP_AUTHOR}" --pretty=format:"%H" | grep -Fxv -f /tmp/backup_branch_commits.txt > /tmp/to_backup.txt || true

[ -s /tmp/to_backup.txt ] || { echo "Không có commit mới để backup"; exit 0; }

cd /tmp/backup-repo

merge_or_create_file() {
  file="$1"
  commit="$2"
  git -C "$GITHUB_WORKSPACE" show "${commit}:${file}" > file.new || return 1

  if [ ! -f "$file" ]; then
    mv file.new "$file"
    git add "$file"
    echo "Add file mới $file"
    return 0
  fi

  if cmp -s "$file" file.new; then
    rm file.new
    echo "Trùng nội dung $file, bỏ qua."
    return 1
  fi

  cp "$file" file.base
  if git merge-file -p "$file" file.base file.new > file.merge 2>/dev/null; then
    if grep -q '<<<<<<<' file.merge; then
      ext=""
      base="$file"
      if [[ "$file" == *.* ]]; then
        base="${file%.*}"
        ext=".${file##*.}"
      fi
      oldfile="${base}_backup_$(date +'%Y%m%d%H%M%S')${ext}"
      mv "$file" "$oldfile"
      git add "$oldfile"
      mv file.new "$file"
      git add "$file"
      echo "Xung đột, đổi tên file cũ thành $oldfile, file mới giữ tên $file"
      rm -f file.base file.merge
      return 0
    else
      mv file.merge "$file"
      git add "$file"
      echo "Merge thành công file $file"
      rm -f file.base file.new
      return 0
    fi
  else
    ext=""
    base="$file"
    if [[ "$file" == *.* ]]; then
      base="${file%.*}"
      ext=".${file##*.}"
    fi
    oldfile="${base}_backup_$(date +'%Y%m%d%H%M%S')${ext}"
    mv "$file" "$oldfile"
    git add "$oldfile"
    mv file.new "$file"
    git add "$file"
    echo "Merge lỗi, đổi tên file cũ thành $oldfile, file mới giữ tên $file"
    rm -f file.base file.merge
    return 0
  fi
}

while IFS= read -r commit; do
  AUTHOR_NAME=$(git -C "$GITHUB_WORKSPACE" show -s --format='%an' $commit)
  AUTHOR_EMAIL=$(git -C "$GITHUB_WORKSPACE" show -s --format='%ae' $commit)
  AUTHOR_DATE=$(git -C "$GITHUB_WORKSPACE" show -s --format='%ad' --date=iso-strict $commit)
  COMMIT_MSG=$(git -C "$GITHUB_WORKSPACE" show -s --format='%s' $commit)
  changed_any=0

  mapfile -t changed_files < <(git -C "$GITHUB_WORKSPACE" diff-tree --no-commit-id --name-only -r $commit)
  for file in "${changed_files[@]}"; do
    mkdir -p "$(dirname "$file")"
    if git -C "$GITHUB_WORKSPACE" cat-file -e "${commit}:${file}" 2>/dev/null; then
      if merge_or_create_file "$file" "$commit"; then
        changed_any=1
      fi
    fi
  done

  if [ "$changed_any" = "1" ]; then
    export GIT_COMMITTER_NAME="$AUTHOR_NAME"
    export GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL"
    export GIT_COMMITTER_DATE="$AUTHOR_DATE"
    git commit --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" --date="$AUTHOR_DATE" -m "$COMMIT_MSG" || true
  else
    echo "Không có file mới nào cần commit cho commit $commit"
  fi
done < <(tac /tmp/to_backup.txt)

git push origin HEAD:refs/heads/${BACKUP_BRANCH}
cd "$GITHUB_WORKSPACE"

echo "$BACKUP_PATHS" | tr -d '\r' | sed '/^\s*$/d' > /tmp/backup_paths.txt

set +e
shopt -s nullglob globstar
mkdir -p /tmp/backup
while IFS= read -r path || [[ -n "$path" ]]; do
  for src in $path; do
    if [ -e "$src" ]; then
      dest="/tmp/backup/$src"
      mkdir -p "$(dirname "$dest")"
      cp -a "$src" "$dest"
    fi
  done
done < /tmp/backup_paths.txt
shopt -u nullglob globstar
set -e

SELECTED_BRANCH2="${SOURCE_BRANCH_MANUAL}"
if [ -z "$SELECTED_BRANCH2" ]; then
  for b in main master; do
    if git ls-remote --exit-code --heads origin $b; then
      SELECTED_BRANCH2="$b"
      break
    fi
  done
fi
if [ -z "$SELECTED_BRANCH2" ]; then
  echo "Không tìm thấy branch main hoặc master!"
  exit 1
fi

git remote add upstream "$UPSTREAM_URL" || true
git fetch upstream
git reset --hard upstream/$SELECTED_BRANCH2

echo "$REPLACE_RULES_1" | while IFS='|' read -r filepath from to; do
  [ -z "$filepath" ] && continue
  [ ! -f "$filepath" ] && continue
  if [ -z "$to" ]; then
    sed -i "/^$from$/d" "$filepath"
  else
    sed -i "s|^$from\$|$to|g" "$filepath"
  fi
done

echo "$REPLACE_RULES_2" | while IFS='|' read -r filepath from to; do
  [ -z "$filepath" ] && continue
  [ ! -f "$filepath" ] && continue
  if [ -z "$to" ]; then
    sed -i "s|$from||gI" "$filepath"
  else
    sed -i "s|$from|$to|gI" "$filepath"
  fi
done

cd /tmp/backup
find . -type f -o -type d | tail -n +2 | while read path; do
  target="${path#./}"
  if [ -f "$path" ]; then
    mkdir -p "$(dirname "$GITHUB_WORKSPACE/$target")"
    cp -a "$path" "$GITHUB_WORKSPACE/$target"
  fi
  if [ -d "$path" ] && [ -z "$(ls -A "$path")" ]; then
    mkdir -p "$GITHUB_WORKSPACE/$target"
  fi
done
cd "$GITHUB_WORKSPACE"

git add .
git_branch=$(git rev-parse --abbrev-ref HEAD)
git diff --cached --exit-code || (git commit -m "Sync upstream và thay thế keyword chính xác/khớp từ" && git push --force origin "$git_branch")