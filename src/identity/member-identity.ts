export type MemberIdentityInput = {
  userId: string;
  profileFullName?: string | null;
  profileFirstName?: string | null;
  profileLastName?: string | null;
  metadataDisplayName?: string | null;
  email?: string | null;
};

const present = (value?: string | null) => value?.trim() || null;

export function shortenedMemberIdentifier(userId: string): string {
  return `Member ${userId.slice(0, 8)}`;
}

export function resolveMemberDisplayName(identity: MemberIdentityInput): string {
  const profileName = present(identity.profileFullName);
  if (profileName) return profileName;
  const splitName = [present(identity.profileFirstName), present(identity.profileLastName)].filter(Boolean).join(' ');
  if (splitName) return splitName;
  return present(identity.metadataDisplayName)
    ?? present(identity.email)
    ?? shortenedMemberIdentifier(identity.userId);
}
