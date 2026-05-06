public with sharing class AmplemarketDTO {

    public static final String OBJECT_LEAD = 'Lead';
    public static final String OBJECT_CONTACT = 'Contact';
    public static final String OBJECT_ACCOUNT = 'Account';

    public static final String MAPPING_MATCH_INPUT = 'Match Input';
    public static final String MAPPING_OUTPUT_FIELD = 'Output Field';

    public static final Set<String> PERSON_OBJECTS = new Set<String>{ OBJECT_LEAD, OBJECT_CONTACT };
    public static final Set<String> COMPANY_OBJECTS = new Set<String>{ OBJECT_ACCOUNT };

    public static final Set<String> PERSON_MATCH_KEYS = new Set<String>{
        'email', 'linkedin_url', 'name', 'title', 'company_name', 'company_domain'
    };
    public static final Set<String> COMPANY_MATCH_KEYS = new Set<String>{
        'domain', 'linkedin_url'
    };

    /**
     * Catalog of Amplemarket response fields the LWC offers as output mapping targets.
     * Keys are JSON dot-paths into the response. Values are human-readable labels.
     */
    public static final Map<String, String> PERSON_OUTPUT_FIELDS = new Map<String, String>{
        'name' => 'Name',
        'first_name' => 'First Name',
        'last_name' => 'Last Name',
        'gender' => 'Gender',
        'linkedin_url' => 'LinkedIn URL',
        'image_url' => 'Image URL',
        'title' => 'Title',
        'headline' => 'Headline',
        'about' => 'About',
        'current_position_start_date' => 'Current Position Start Date',
        'current_position_description' => 'Current Position Description',
        'location' => 'Location',
        'location_details.city' => 'Location: City',
        'location_details.state' => 'Location: State',
        'location_details.country' => 'Location: Country',
        'company.name' => 'Company Name',
        'company.website' => 'Company Website',
        'company.linkedin_url' => 'Company LinkedIn',
        'company.size' => 'Company Size',
        'company.estimated_number_of_employees' => 'Company Employees',
        'company.industry' => 'Company Industry',
        'email' => 'Email (revealed)',
        'phone_numbers[0].number' => 'Primary Phone (revealed)'
    };

    public static final Map<String, String> COMPANY_OUTPUT_FIELDS = new Map<String, String>{
        'name' => 'Company Name',
        'website' => 'Website',
        'linkedin_url' => 'LinkedIn URL',
        'overview' => 'Overview',
        'estimated_number_of_employees' => 'Employees',
        'followers' => 'Followers',
        'founded_year' => 'Founded Year',
        'traffic_rank' => 'Traffic Rank',
        'size' => 'Size',
        'type' => 'Type',
        'location' => 'Location',
        'location_details.city' => 'Location: City',
        'location_details.state' => 'Location: State',
        'location_details.country' => 'Location: Country',
        'total_funding' => 'Total Funding',
        'revenue' => 'Revenue',
        'latest_funding_stage' => 'Latest Funding Stage',
        'latest_funding_date' => 'Latest Funding Date',
        'estimated_revenue' => 'Estimated Revenue',
        'is_b2b' => 'Is B2B',
        'is_b2c' => 'Is B2C'
    };

    public static Boolean isPersonObject(String objectApiName) {
        return PERSON_OBJECTS.contains(objectApiName);
    }

    public static Boolean isCompanyObject(String objectApiName) {
        return COMPANY_OBJECTS.contains(objectApiName);
    }

    public static Map<String, String> outputCatalogFor(String objectApiName) {
        if (isPersonObject(objectApiName)) return PERSON_OUTPUT_FIELDS;
        if (isCompanyObject(objectApiName)) return COMPANY_OUTPUT_FIELDS;
        return new Map<String, String>();
    }

    public static Set<String> matchKeysFor(String objectApiName) {
        if (isPersonObject(objectApiName)) return PERSON_MATCH_KEYS;
        if (isCompanyObject(objectApiName)) return COMPANY_MATCH_KEYS;
        return new Set<String>();
    }
}
