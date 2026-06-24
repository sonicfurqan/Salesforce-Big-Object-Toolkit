/**
 * Inspects whether the current org domain is approved as a Remote Site Setting.
 */
public with sharing class BIGOTOOL_RemoteSiteGuard {
  private static final Double METADATA_API_VERSION = 60.0;

  @TestVisible
  static Boolean testRemoteSiteConfigured;

  @TestVisible
  static String testRequiredRemoteSiteUrl;

  /**
   * Result returned to callers that need to gate UI or callout behavior.
   */
  public class RemoteSiteCheck {
    public Boolean isConfigured;
    public String requiredUrl;

    /**
     * Builds a remote-site status snapshot.
     *
     * @param isConfigured Whether the org domain is already approved.
     * @param requiredUrl The org-domain URL that must be whitelisted.
     */
    public RemoteSiteCheck(Boolean isConfigured, String requiredUrl) {
      this.isConfigured = isConfigured;
      this.requiredUrl = requiredUrl;
    }
  }

  /**
   * Checks whether the current org domain is present in Remote Site Settings.
   *
   * @return The current org remote-site status.
   */
  public static RemoteSiteCheck checkCurrentOrg() {
    String requiredUrl = String.isBlank(testRequiredRemoteSiteUrl)
      ? URL.getOrgDomainUrl().toExternalForm()
      : testRequiredRemoteSiteUrl;
    if (Test.isRunningTest()) {
      return new RemoteSiteCheck(testRemoteSiteConfigured != false, requiredUrl);
    }
    return new RemoteSiteCheck(isConfiguredByCallout(), requiredUrl);
  }

  /**
   * Uses a lightweight Metadata API callout to verify self-callout access.
   * If this call fails, org remote-site (or session/API) configuration is not usable.
   */
  private static Boolean isConfiguredByCallout() {
    try {
      MetadataService.MetadataPort service = BIGOTOOL_MetadataGenerator.createService();
      service.describeMetadata(METADATA_API_VERSION);
      return true;
    } catch (Exception e) {
      return false;
    }
  }
}
