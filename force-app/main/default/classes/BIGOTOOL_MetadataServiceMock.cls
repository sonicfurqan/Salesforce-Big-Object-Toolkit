/**
 * BIGOTOOL_MetadataServiceMock
 *
 * WebServiceMock for the Metadata API createMetadata SOAP callout used by the
 * generation engine. Returns either success or failure SaveResults so both the
 * happy path and the error path can be exercised in tests.
 */
@IsTest
public class BIGOTOOL_MetadataServiceMock implements WebServiceMock {
  private final Boolean succeed;

  public BIGOTOOL_MetadataServiceMock(Boolean succeed) {
    this.succeed = succeed;
  }

  public void doInvoke(
    Object stub,
    Object request,
    Map<String, Object> response,
    String endpoint,
    String soapAction,
    String requestName,
    String responseNS,
    String responseName,
    String responseType
  ) {
    MetadataService.SaveResult sr = new MetadataService.SaveResult();
    sr.success = succeed;
    sr.fullName = 'Mock';
    if (!succeed) {
      MetadataService.Error err = new MetadataService.Error();
      err.statusCode = 'INVALID_FIELD';
      err.message = 'Simulated failure';
      sr.errors = new List<MetadataService.Error>{ err };
    }

    MetadataService.createMetadataResponse_element resp =
      new MetadataService.createMetadataResponse_element();
    resp.result = new List<MetadataService.SaveResult>{ sr };
    response.put('response_x', resp);
  }
}
