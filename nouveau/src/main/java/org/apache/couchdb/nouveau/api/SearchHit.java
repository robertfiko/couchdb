//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package org.apache.couchdb.nouveau.api;

import java.util.Collection;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

import io.dropwizard.jackson.JsonSnakeCase;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
@JsonSnakeCase
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class SearchHit {

    @NotEmpty
    private String id;

    @NotNull
    private After order;

    @NotNull
    private Collection<@NotNull StoredField> fields;

    public SearchHit() {
    }

    public SearchHit(final String id, final After order, final Collection<StoredField> fields) {
        this.id = id;
        this.order = order;
        this.fields = fields;
    }

    public String getId() {
        return id;
    }

    public After getOrder() {
        return order;
    }

    public Collection<StoredField> getFields() {
        return fields;
    }

    @Override
    public String toString() {
        return "SearchHit [id=" + id + ", order=" + order + ", fields=" + fields + "]";
    }

}
