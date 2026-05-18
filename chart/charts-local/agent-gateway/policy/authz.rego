package ag_gateway.authz

# Coarse "can user reach MCP at all" check.
# Per-tool authorization is enforced by each MCP under the hybrid authz model.

# default decision: deny
default decision := {"allow": false, "reason": "default_deny"}

# allow when the user has the minimum permission required to reach this MCP
decision := {"allow": true, "reason": "ok"} if {
    required := data.permissions[input.mcp]
    required in input.user.permissions
}

# explicit reason for the common "missing permission" case
decision := {"allow": false, "reason": reason} if {
    required := data.permissions[input.mcp]
    not required in input.user.permissions
    reason := sprintf("missing_permission:%s", [required])
}

# explicit reason when the MCP isn't registered (treat as deny — never silently allow)
decision := {"allow": false, "reason": "unknown_mcp"} if {
    not data.permissions[input.mcp]
}
