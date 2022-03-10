#!/bin/bash
# shellcheck disable=SC2016

echo "- Get project and field data"

gh api graphql \
  --header 'GraphQL-Features: projects_next_graphql' \
  -f query='
    query($org: String!, $number: Int!) {
      organization(login: $org){
        projectNext(number: $number) {
          id
          fields(first:20) {
            nodes {
              id
              name
              settings
            }
          }
        }
      }
    }
' \
  -f org="$ORGANIZATION" \
  -F number="$PROJECT_NUMBER" >project_data.json

PROJECT_ID="$(jq --raw-output '.data.organization.projectNext.id' project_data.json)"
STATUS_FIELD_ID="$(jq --raw-output '.data.organization.projectNext.fields.nodes[] | select(.name== "Status") | .id' project_data.json)"
STATUS_FIELD_VALUE_ID="$(jq --arg column "$TARGET_COLUMN" --raw-output '.data.organization.projectNext.fields.nodes[] | select(.name== "Status") | .settings | fromjson.options[] | select(.name==$column) | .id' project_data.json)"

# Check if issue is not yet on project board
echo "- Looking for issue $ISSUE_ID in project $PROJECT_ID"

# Paginated API call results to multiple cnnsequent calls (but automatically).
gh api graphql --paginate \
  --header 'GraphQL-Features: projects_next_graphql' \
  -f query='
    query ($project_id: ID!, $endCursor: String) {
      node(id: $project_id) {
        ... on ProjectNext {
          items(first: 100, after: $endCursor) {
            nodes {
              content {
                ...on Issue {
                  id
                  # title
                }
              }
              } pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    }
' \
  -f project_id="$PROJECT_ID" >>board_issues.json

EXISTS=$(jq '.data.node.items.nodes[].content.id' board_issues.json | grep -c "$ISSUE_ID" || :)

if [[ $EXISTS -eq 0 ]]; then
  echo "- Issue not found in project"
  echo "- Add Issue to the project board"

  # Adding item to the board and a column is 2 step mutation. You must use
  # `addProjectNextItem` to add the item and then use
  # `updateProjectNextItemField` to update the item.
  # @see https://docs.github.com/en/issues/trying-out-the-new-projects-experience/using-the-api-to-manage-projects#adding-an-item-to-a-project
  gh api graphql \
    --header 'GraphQL-Features: projects_next_graphql' \
    -f query='
      mutation ($project_id: ID!, $content_id: ID!) {
        addProjectNextItem(input: {projectId: $project_id, contentId: $content_id }) {
          projectNextItem {
            id
          }
        }
      }
    ' \
    -f project_id="$PROJECT_ID" \
    -f content_id="$ISSUE_ID" \
    --jq '.data.addProjectNextItem.projectNextItem.id' >new_item_id.txt

  ITEM_ID=$(cat new_item_id.txt)

  echo "- New board item id is ${ITEM_ID}."
  echo "- Update the status field (the kanban column)"

  # Keep --include option to see response headers in Action logs.
  # It may be useful if the token expires or does not have all credentials it needs since
  # response headers reveals useful information such as accepted token scope.
  gh api graphql \
    --include \
    --header 'GraphQL-Features: projects_next_graphql' \
    -f query='
      mutation (
        $project: ID!
        $item: ID!
        $status_field: ID!
        $status_value: String!
        ) {
        set_status: updateProjectNextItemField ( input: {
            projectId: $project
            itemId: $item
            fieldId: $status_field
            value: $status_value
          }) {
          projectNextItem {
            id
          }
        }
      }
    ' \
    -f project="$PROJECT_ID" \
    -f item="$ITEM_ID" \
    -f status_field="$STATUS_FIELD_ID" \
    -f status_value="$STATUS_FIELD_VALUE_ID"
else
  echo "- Issue $ISSUE_ID is already in the project"
fi
