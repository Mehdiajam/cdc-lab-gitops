import json

with open("debezium.json", "r") as f:
    dashboard = json.load(f)

for var in dashboard.get("templating", {}).get("list", []):
    name = var.get("name")
    if name == "name":
        var["query"]["query"] = "label_values(debezium_metrics_binlogposition, name)"
        var["regex"] = ""
    elif name == "instance":
        var["query"]["query"] = "label_values(debezium_metrics_binlogposition, instance)"
        var["regex"] = ""
    elif name == "context":
        var["query"]["query"] = "label_values(debezium_metrics_millisecondssincelastevent, context)"
        var["regex"] = ""
    elif name == "plugin":
        var["query"]["query"] = "label_values(debezium_metrics_binlogposition, plugin)"
        var["regex"] = ""

with open("debezium_fixed.json", "w") as f:
    json.dump(dashboard, f, indent=2)
