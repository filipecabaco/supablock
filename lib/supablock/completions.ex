defmodule Supablock.Completions do
  @moduledoc """
  Shell completion scripts (`supablock completions bash|zsh|fish`).

  Subcommands and config keys complete statically; tree paths complete by
  asking `supablock ls` for the parent directory — instant against a warm
  daemon (mount or `supablock serve`), one cached API call otherwise.

  Install:

      # bash (~/.bashrc)
      eval "$(supablock completions bash)"

      # zsh (~/.zshrc)
      eval "$(supablock completions zsh)"

      # fish
      supablock completions fish > ~/.config/fish/completions/supablock.fish
  """

  @commands ~w(setup login logout status whoami doctor config mount unmount ls cat head tail find grep snapshot diff mcp serve refresh service completions help)

  @path_commands ~w(ls cat head tail find grep)

  @doc "The completion script for `shell`, or :unknown."
  @spec script(String.t()) :: {:ok, binary} | :unknown
  def script("bash"), do: {:ok, bash()}
  def script("zsh"), do: {:ok, zsh()}
  def script("fish"), do: {:ok, fish()}
  def script(_other), do: :unknown

  @doc false
  def commands, do: @commands

  defp config_keys, do: Enum.join(Supablock.Config.valid_keys(), " ")

  defp bash do
    """
    # supablock bash completion — eval "$(supablock completions bash)"
    _supablock_paths() {
      local cur="$1" parent entries
      if [[ "$cur" == */* ]]; then parent="${cur%/*}"; else parent=""; fi
      entries=$(supablock ls "${parent:-/}" 2>/dev/null) || return
      if [ -n "$parent" ]; then
        entries=$(printf '%s\\n' "$entries" | sed "s|^|$parent/|")
      fi
      COMPREPLY=($(compgen -W "$entries" -- "$cur"))
      # entries may be directories the user will descend into
      [ ${#COMPREPLY[@]} -eq 1 ] && compopt -o nospace 2>/dev/null
    }

    _supablock() {
      local cur prev
      COMPREPLY=()
      cur="${COMP_WORDS[COMP_CWORD]}"
      prev="${COMP_WORDS[COMP_CWORD - 1]}"

      if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "#{Enum.join(@commands, " ")}" -- "$cur"))
        return
      fi

      case "${COMP_WORDS[1]}" in
        config)
          if [ "$COMP_CWORD" -eq 2 ]; then
            COMPREPLY=($(compgen -W "set get list" -- "$cur"))
          elif [ "$COMP_CWORD" -eq 3 ]; then
            COMPREPLY=($(compgen -W "#{config_keys()}" -- "$cur"))
          fi
          ;;
        service)
          COMPREPLY=($(compgen -W "install uninstall status" -- "$cur"))
          ;;
        serve)
          COMPREPLY=($(compgen -W "stop" -- "$cur"))
          ;;
        refresh)
          COMPREPLY=($(compgen -W "--check" -- "$cur"))
          ;;
        completions)
          COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
          ;;
        snapshot|diff)
          if [ "$COMP_CWORD" -eq 2 ]; then
            compopt -o default 2>/dev/null
          else
            _supablock_paths "$cur"
          fi
          ;;
        #{Enum.join(@path_commands, "|")})
          case "$cur" in
            -*) COMPREPLY=($(compgen -W "-n -f -s -0 -type -name -maxdepth -print0 -i -l --maxdepth" -- "$cur")) ;;
            *) _supablock_paths "$cur" ;;
          esac
          ;;
      esac
    }
    complete -F _supablock supablock
    """
  end

  defp zsh do
    """
    # supablock zsh completion — eval "$(supablock completions zsh)"
    _supablock_paths() {
      local cur="${words[CURRENT]}" parent entries
      if [[ "$cur" == */* ]]; then parent="${cur%/*}"; else parent=""; fi
      entries=(${(f)"$(supablock ls "${parent:-/}" 2>/dev/null)"}) || return
      if [ -n "$parent" ]; then
        entries=(${entries[@]/#/$parent/})
      fi
      compadd -q -S '' -- $entries
    }

    _supablock() {
      if (( CURRENT == 2 )); then
        compadd -- #{Enum.join(@commands, " ")}
        return
      fi

      case "$words[2]" in
        config)
          if (( CURRENT == 3 )); then
            compadd -- set get list
          elif (( CURRENT == 4 )); then
            compadd -- #{config_keys()}
          fi
          ;;
        service) compadd -- install uninstall status ;;
        serve) compadd -- stop ;;
        refresh) compadd -- --check ;;
        completions) compadd -- bash zsh fish ;;
        snapshot|diff)
          if (( CURRENT == 3 )); then _files; else _supablock_paths; fi
          ;;
        #{Enum.join(@path_commands, "|")}) _supablock_paths ;;
      esac
    }
    compdef _supablock supablock
    """
  end

  defp fish do
    """
    # supablock fish completion — write to ~/.config/fish/completions/supablock.fish
    function __supablock_paths
      set -l cur (commandline -ct)
      set -l parent ""
      if string match -q "*/*" -- $cur
        set parent (string replace -r '/[^/]*$' '' -- $cur)
      end
      if test -n "$parent"
        supablock ls "$parent" 2>/dev/null | sed "s|^|$parent/|"
      else
        supablock ls / 2>/dev/null
      end
    end

    function __supablock_no_subcommand
      not __fish_seen_subcommand_from #{Enum.join(@commands, " ")}
    end

    complete -c supablock -f
    """ <>
      Enum.map_join(@commands, "", fn command ->
        "complete -c supablock -n __supablock_no_subcommand -a #{command}\n"
      end) <>
      """
      complete -c supablock -n '__fish_seen_subcommand_from config' -a 'set get list'
      complete -c supablock -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from set get' -a '#{config_keys()}'
      complete -c supablock -n '__fish_seen_subcommand_from service' -a 'install uninstall status'
      complete -c supablock -n '__fish_seen_subcommand_from serve' -a 'stop'
      complete -c supablock -n '__fish_seen_subcommand_from refresh' -a '--check'
      complete -c supablock -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'
      complete -c supablock -n '__fish_seen_subcommand_from #{Enum.join(@path_commands, " ")} snapshot diff' -a '(__supablock_paths)'
      """
  end
end
