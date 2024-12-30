#!/bin/bash

# Function to get object type
get_object_type() {
  git cat-file -t "$1" 2>/dev/null
}

# Function to get tree entries
get_tree_entries() {
  git ls-tree "$1" 2>/dev/null
}

# Function to get parent commits
get_parent_commits() {
  local commit_hash="$1"
  local commit_data=$(git cat-file -p "$commit_hash" 2>/dev/null)
  echo "$commit_data" | grep "^parent" | cut -d' ' -f2
}

# Function to get all objects (commits, trees, blobs)
get_all_objects() {
  local objects=$(git rev-list --all --objects 2>/dev/null)
  echo "$objects"
}

# Function to make ref names graphviz-safe
sanitize_ref() {
  echo "$1" | sed 's/\//_/g'
}

# Function to get all refs and their targets
get_refs() {
  local refs_file="$1"
  local edges_file="$2"

  # Get all refs
  git show-ref | while read -r hash ref; do
    # Skip HEAD since we'll handle it separately
    if [[ "$ref" != "refs/heads/HEAD" ]]; then
      # Clean up ref name for display and make graphviz-safe
      local ref_name=${ref#refs/}
      local safe_ref=$(sanitize_ref "$ref")
      echo "    \"$safe_ref\" [label=\"$ref_name\", shape=box, style=filled, fillcolor=\"burlywood\", color=\"burlywood\"];" >> "$refs_file"
      echo "  \"$safe_ref\" -> \"$hash\" [color=\"burlywood\", label=\"points_to\"];" >> "$edges_file"
    fi
  done

  # Handle HEAD specially
  local head_target=$(git symbolic-ref HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null)
  local safe_head_target=$(sanitize_ref "$head_target")
  echo "    \"HEAD\" [label=\"HEAD\", shape=box, style=filled, fillcolor=\"red\", color=\"red\"];" >> "$refs_file"
  
  # If HEAD is symbolic ref (points to branch)
  if git symbolic-ref HEAD &>/dev/null; then
    echo "  \"HEAD\" -> \"$safe_head_target\" [color=\"red\", label=\"points_to\"];" >> "$edges_file"
  else
    # If HEAD is detached, point directly to commit
    echo "  \"HEAD\" -> \"$head_target\" [color=\"red\", label=\"points_to\"];" >> "$edges_file"
  fi
}

# Main function to generate Graphviz output
generate_graphviz() {
  local output_file="git_graph.dot"
  
  # Initialize temporary files for each object type
  local commits_file="commits.tmp"
  local trees_file="trees.tmp"
  local blobs_file="blobs.tmp"
  local edges_file="edges.tmp"
  local refs_file="refs.tmp"
  local commit_list_file="commit_list.tmp"
  
  # Clear or create temporary files
  > "$commits_file"
  > "$trees_file"
  > "$blobs_file"
  > "$edges_file"
  > "$refs_file"
  > "$commit_list_file"

  # Start the graph
  echo "digraph git_objects {" > "$output_file"
  echo "  graph [rankdir=LR];" >> "$output_file"

  # Get all objects
  all_objects=$(get_all_objects)

  # Process all objects and write to temporary files
  for object_hash in $all_objects; do
    local object_type=$(get_object_type "$object_hash")

    case "$object_type" in
      commit)
        echo "    \"$object_hash\" [label=\"Commit: $object_hash\", shape=box, style=filled, fillcolor=\"lightblue\", color=\"lightblue\"];" >> "$commits_file"
        echo "\"$object_hash\"" >> "$commit_list_file"
        process_commit "$object_hash" "$edges_file"
        ;;
      tree)
        echo "    \"$object_hash\" [label=\"Tree: $object_hash\", shape=box, style=filled, fillcolor=\"lightgreen\", color=\"lightgreen\"];" >> "$trees_file"
        process_tree "$object_hash" "$edges_file" "$blobs_file"
        ;;
      blob)
        continue
        ;;
    esac
  done

  # Process refs and HEAD
  get_refs "$refs_file" "$edges_file"

  # Build the rank statement for commits
  local rank_stmt="    {rank=same; "
  local commit_hashes=$(cat "$commit_list_file" | tr '\n' ' ')
  rank_stmt+="$commit_hashes}"

  # Build the rank statement for refs - now with explicit list
  local refs_rank="    {rank=same; HEAD; $(git show-ref | cut -d' ' -f2 | grep -v "refs/heads/HEAD" | sed 's/\//_/g' | tr '\n' ' ')}"

  # Write subgraphs to main file
  echo "  subgraph cluster_refs {" >> "$output_file"
  echo "    label=\"References\";" >> "$output_file"
  echo "    style=dotted;" >> "$output_file"
  # Only include refs_rank if we actually have refs
  if [ -s "$refs_file" ]; then
    echo "$refs_rank" >> "$output_file"
  fi
  cat "$refs_file" >> "$output_file"
  echo "  }" >> "$output_file"

  echo "  subgraph cluster_commits {" >> "$output_file"
  echo "    label=\"Commits\";" >> "$output_file"
  echo "    style=dotted;" >> "$output_file"
  echo "$rank_stmt" >> "$output_file"
  cat "$commits_file" >> "$output_file"
  echo "  }" >> "$output_file"

  echo "  subgraph cluster_trees {" >> "$output_file"
  echo "    label=\"Trees\";" >> "$output_file"
  echo "    style=dotted;" >> "$output_file"
  cat "$trees_file" >> "$output_file"
  echo "  }" >> "$output_file"

  echo "  subgraph cluster_blobs {" >> "$output_file"
  echo "    label=\"Blobs\";" >> "$output_file"
  echo "    style=dotted;" >> "$output_file"
  cat "$blobs_file" >> "$output_file"
  echo "  }" >> "$output_file"

  # Add all edges after the subgraphs
  cat "$edges_file" >> "$output_file"

  # Close the graph
  echo "}" >> "$output_file"

  # Clean up temporary files
  rm -f "$commits_file" "$trees_file" "$blobs_file" "$edges_file" "$refs_file" "$commit_list_file"

  echo "Graphviz output generated in $output_file"
}

# Process commit objects
process_commit() {
  local commit_hash="$1"
  local edges_file="$2"
  local commit_data=$(git cat-file -p "$commit_hash" 2>/dev/null)

  # Extract tree hash from commit data
  local tree_hash=$(awk '/tree / {print $2}' <<< "$commit_data")

  # Add pointer from commit to tree
  echo "  \"$commit_hash\" -> \"$tree_hash\" [color=\"lightblue\", label=\"tree\"];" >> "$edges_file"

  # Get parent commits directly from commit data
  local parent_commits=$(get_parent_commits "$commit_hash")
  while IFS= read -r parent_hash; do
    if [ -n "$parent_hash" ]; then 
      echo "  \"$commit_hash\" -> \"$parent_hash\" [color=\"red\", label=\"parent\"];" >> "$edges_file"
    fi
  done <<< "$parent_commits"
}

# Process tree objects
process_tree() {
  local tree_hash="$1"
  local edges_file="$2"
  local blobs_file="$3"

  # Get tree entries
  local tree_entries=$(get_tree_entries "$tree_hash")

  # Process each entry (blob or subtree)
  while IFS=' ' read -r mode type hash name || [[ -n "$mode" ]]; do
    if [[ -n "$type" && -n "$hash" ]]; then
      if [[ "$type" == "blob" ]]; then
        # Check if we've already processed this blob
        if ! grep -q "\"$hash\"" "$blobs_file"; then
          echo "    \"$hash\" [label=\"Blob: $hash\\n$name\", shape=box, style=filled, fillcolor=\"purple\", color=\"purple\"];" >> "$blobs_file"
        fi
        echo "  \"$tree_hash\" -> \"$hash\" [color=\"lightgreen\", label=\"blob\"];" >> "$edges_file"
      elif [[ "$type" == "tree" ]]; then
        echo "  \"$tree_hash\" -> \"$hash\" [color=\"lightgreen\", label=\"tree\"];" >> "$edges_file"
      fi
    fi
  done <<< "$tree_entries"
}

# Call the main function
generate_graphviz
