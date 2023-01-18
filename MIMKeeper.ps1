[CmdletBinding()]
Param(
        [string]$ConfigFile = "MIMKeeper.json",
        [switch]$WhatIf)
Begin{
    Write-Host "***" -ForegroundColor Black -BackgroundColor White;
    Write-Host "*** Start of MIM Keeper ***" -ForegroundColor Black -BackgroundColor White;
    Write-Host "***" -ForegroundColor Black -BackgroundColor White;
    
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew();
    
    Import-Module LithnetRMA;
}
Process{

    Write-Debug "The configuration file is $ConfigFile";
    $JSON = Get-Content $ConfigFile | Out-String | ConvertFrom-Json;

    $CachedObjects = @{};

    foreach($Object in $JSON.MIMKeeper.Objects.Object){
        # Retrieve all MIM Objects
        $ObjectXpath = $Object.XPath;
        $ObjectType = $Object.Type;
        Write-Verbose "Searching for $ObjectType objects with xpath $ObjectXpath";
        
        $RMObjects = Search-Resources -XPath $ObjectXpath -ExpectedObjectType $ObjectType;
        Write-Verbose "Found $($RMObjects.Count) object(s)";

        # Cache the object, to avoid unnecessaries calls
        $RMObjects | ForEach-Object { 
            if(-not($CachedObjects.ContainsKey($_.ObjectID.Value))){
                $CachedObjects.Add($_.ObjectID.Value,$_);
            }
        };
       
       $ObjectsToSave = @();

        foreach($ReferencedObject in $Object.ReferencedObjects.ReferencedObject){
            $ReferencedXpath = $ReferencedObject.Xpath;
            $ReferencedType = $ReferencedObject.Type;
            $ReferencedAttributeReference = $ReferencedObject.AttributeReference;

            if(-not($ReferencedXpath)){
                $ReferencedXpath = "/{0}[{1}=/{2}]/{1}" -f @($ReferencedType,$ReferencedAttributeReference,$ObjectType)
            }

            Write-Verbose "Searching for reference $ReferencedType objects with xpath $ReferencedXpath";

            # Retrieve all MIM Referenced Objects
            $RMReferencedObjects = Search-Resources -XPath $ReferencedXpath -ExpectedObjectType $ReferencedType
            Write-Verbose "Found $($RMReferencedObjects.Count) reference object(s)";

            # Loop over all MIM Objects to update the attributes
            $i = 1;
            $total = $RMObjects.Count;
            foreach($RMObject in $RMObjects){
                Write-Progress -Activity "Checking $ObjectType with reference $ReferencedType in Progress" -Status "$i / $total [$([math]::Round($i/$total*100,2))%] Complete:" -PercentComplete $($i/$total*100);
                $i++;
                if($ReferencedObject.Mode -eq "AttributeEquality"){
                    # In AttributeEquality Mode
                    # Get the attribute value on the MIM object
                    $AttributeValue = $RMObject.$($ReferencedAttributeReference);
                    # Get the MIM referenced object by filtering with the attribute value 
                    $RMReferencedObject = $RMReferencedObjects | Where-Object { $_.$($ReferencedAttributeReference) -eq $AttributeValue; };
                }
                elseif ($ReferencedObject.Mode -eq "Reversed"){
                    # In Reversed Mode
                    # Get the object id of the MIM object
                    $ObjectID = $RMObject.ObjectID;
                    # Get the MIM "referenced" object by filtering with the object id on the reference attribute
                    $RMReferencedObject = $RMReferencedObjects | Where-Object { ($_.$($ReferencedAttributeReference)).Value -eq $ObjectID.Value; };
                }
                else {
                    # In Normal mode
                    # Get the reference id on the MIM object
                    $ReferenceID = $RMObject.$($ReferencedAttributeReference);
                    # Get the MIM referenced object by filtering with the reference id
                    $RMReferencedObject = $RMReferencedObjects | Where-Object { $_.ObjectID.Value -eq $ReferenceID.Value; };
                } 

                if(($RMReferencedObject -is [array]) -or ($RMReferencedObject.Count -gt 1)) {
                    # too many reference object
                    continue;
                }

                if($RMReferencedObject){
                    foreach($Mapping in $ReferencedObject.Mappings.Mapping){
                        $MappingFrom = $Mapping.From;
                        $MappingTo = $Mapping.To;
                        $MappingUpdateIfNull = $Mapping.UpdateIfNull;

                         if(-not($MappingFrom) -and -not($MappingTo)){
                            # For some reason, the json give empty value, so we skip them
                            continue;
                        }

                        if(($MappingUpdateIfNull) -or (-not($MappingUpdateIfNull) -and ($RMReferencedObject.$($MappingFrom)))){
                            # If UpdateIfNull is allowed 
                            # Else If UpdateIfNull is not allowed and we have a value

                            
                            if ($RMObject.$($MappingTo) -ne $RMReferencedObject.$($MappingFrom)){
                                
                                if($WhatIf){
                                    Write-Host -ForegroundColor Green "Update on [$($RMObject.DisplayName) ($($RMObject.ObjectType))] - $($MappingTo): $($RMObject.$($MappingTo)) -> $($RMReferencedObject.$($MappingFrom))";
                                }

                                if($PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent){
                                    Write-Verbose "Update on [$($RMObject.DisplayName) ($($RMObject.ObjectType))] - $($MappingTo): $($RMObject.$($MappingTo)) -> $($RMReferencedObject.$($MappingFrom))";
                                }

                                # Update the RMobject's attribute based on the RMReferenceObject's attribute
                                $RMObject.$($MappingTo) = $RMReferencedObject.$($MappingFrom);

                                # Set the table for tracking object changes
                                if($ObjectsToSave -notcontains $RMObject.ObjectID.Value){
                                    $ObjectsToSave += $RMObject.ObjectID.Value;
                                }
                            }
                        }
                    }
                }
            }       
        }

        if(-not($WhatIf)){
            $j = 1;
            $totalUpdates = $ObjectsToSave.Count;
            Write-Verbose "$totalUpdates object(s) to update on MIM."
            foreach($RMObject in $RMObjects){
                if($ObjectsToSave -contains $RMObject.ObjectID.Value)
                {   
                    Write-Progress -Activity "Update $ObjectType in Progress" -Status "$j / $totalUpdates [$([math]::Round($j/$totalUpdates*100,2))%] Complete:" -PercentComplete $($j/$totalUpdates*100);
                    $j++;
                    # Only save the object where (at least) a change has been done.
                    Save-Resource $RMObject;
                }
            }
        }

    }
}
End{
    $stopwatch.Stop();
    Write-Host "***" -ForegroundColor Black -BackgroundColor White;
    Write-Host "*** End of MIM Keeper ***" -ForegroundColor Black -BackgroundColor White;
    Write-Host "*** Total duration: $($stopwatch.Elapsed.Hours) hour(s),  $($stopwatch.Elapsed.Minutes) minute(s) and $($stopwatch.Elapsed.Seconds) Second(s) ***" -ForegroundColor Black -BackgroundColor White;
    Write-Host "***" -ForegroundColor Black -BackgroundColor White;
}