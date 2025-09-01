function unalias --description 'alias unalias=functions --erase $argv[1] && funcsave $argv[1]'
  functions --erase $argv[1] && funcsave $argv[1]
end
