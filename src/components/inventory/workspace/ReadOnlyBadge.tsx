import { Eye } from "lucide-react";
import { Badge } from "@/components/ui/badge";

// Admins read the Inventory workspace; only owners change inventory.
export function ReadOnlyBadge() {
  return (
    <Badge variant="secondary" className="gap-1" data-testid="read-only">
      <Eye className="h-3 w-3" />
      Read-only
    </Badge>
  );
}
