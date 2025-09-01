function slotify-update -d "Update slotify versions in test env"
  if test (count $argv) -ne 2
    echo "Usage: slotiy-update <provider> <version>"
    return 1
  end

  set tequity_provider $argv[1]
  set tequity_version $argv[2]

  git pull
  cd ops/envs/tequity/test/ || return 1

  # Check if running on macOS or Linux and use appropriate sed syntax
  if test (uname) = "Darwin"
      sed -i '' "s/\"$tequity_provider\" = \"[^\"]*\"/\"$tequity_provider\" = \"$tequity_version\"/" main.tf
  else
      sed -i "s/\"$tequity_provider\" = \"[^\"]*\"/\"$tequity_provider\" = \"$tequity_version\"/" main.tf
  end

  git add main.tf
  git commit -m "chore(ops): change $tequity_provider version in tequity test"
  terraform apply && git push
  cd - > /dev/null
end
